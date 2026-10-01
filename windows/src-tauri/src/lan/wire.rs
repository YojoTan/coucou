// LAN wire format: identity, handshake, keys and encrypted frames (docs/LAN.md).
// Pure functions over a byte stream, so the whole exchange is tested in-process.

use std::io::{Read, Write};

use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::agreement::{self, EphemeralPrivateKey, UnparsedPublicKey, X25519};
use ring::digest::{digest, SHA256};
use ring::hkdf;
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{self, Ed25519KeyPair, KeyPair};
use serde_json::{json, Value};

pub const PROTO: &[u8] = b"coucou-lan-v1";
pub const MAX_FRAME: usize = 256 * 1024;

// ── Base64 (standard alphabet, padded) ───────────────────────────────────────

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn b64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { B64[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64[n as usize & 63] as char } else { '=' });
    }
    out
}

pub fn unb64(s: &str) -> Option<Vec<u8>> {
    let s = s.trim_end_matches('=');
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        let v = B64.iter().position(|b| *b == c)? as u32;
        acc = acc << 6 | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ── Identity ─────────────────────────────────────────────────────────────────

pub struct Identity {
    pair: Ed25519KeyPair,
    pkcs8: Vec<u8>,
}

impl Identity {
    pub fn generate() -> Option<Identity> {
        let doc = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).ok()?;
        Identity::from_pkcs8(doc.as_ref())
    }

    pub fn from_pkcs8(bytes: &[u8]) -> Option<Identity> {
        let pair = Ed25519KeyPair::from_pkcs8(bytes).ok()?;
        Some(Identity { pair, pkcs8: bytes.to_vec() })
    }

    pub fn pkcs8(&self) -> &[u8] {
        &self.pkcs8
    }

    pub fn public(&self) -> Vec<u8> {
        self.pair.public_key().as_ref().to_vec()
    }

    pub fn id(&self) -> String {
        id_of(&self.public())
    }

    fn sign(&self, msg: &[u8]) -> Vec<u8> {
        self.pair.sign(msg).as_ref().to_vec()
    }
}

/// First 8 bytes of SHA-256(public key), lowercase hex.
pub fn id_of(public: &[u8]) -> String {
    hex(&digest(&SHA256, public).as_ref()[..8])
}

pub fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    let _ = SystemRandom::new().fill(&mut buf);
    hex(&buf)
}

// ── Keys ─────────────────────────────────────────────────────────────────────

pub fn transcript(key_c: &[u8], eph_c: &[u8], key_s: &[u8], eph_s: &[u8]) -> [u8; 32] {
    let mut all = PROTO.to_vec();
    for part in [key_c, eph_c, key_s, eph_s] {
        all.extend_from_slice(part);
    }
    digest(&SHA256, &all).as_ref().try_into().expect("32 bytes")
}

fn signed(role: &str, th: &[u8; 32]) -> Vec<u8> {
    let mut m = PROTO.to_vec();
    m.push(b' ');
    m.extend_from_slice(role.as_bytes());
    m.extend_from_slice(th);
    m
}

fn verify(public: &[u8], msg: &[u8], sig: &[u8]) -> bool {
    signature::UnparsedPublicKey::new(&signature::ED25519, public).verify(msg, sig).is_ok()
}

struct Len(usize);
impl hkdf::KeyType for Len {
    fn len(&self) -> usize {
        self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Keys {
    pub c2s: [u8; 32],
    pub s2c: [u8; 32],
    /// The six digits both users compare when pairing.
    pub code: String,
}

pub fn derive(shared: &[u8], th: &[u8; 32]) -> Keys {
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, th).extract(shared);
    let expand = |info: &[u8], out: &mut [u8]| {
        prk.expand(&[info], Len(out.len())).and_then(|okm| okm.fill(out)).expect("hkdf length");
    };
    let (mut c2s, mut s2c, mut sas) = ([0u8; 32], [0u8; 32], [0u8; 4]);
    expand(b"c2s", &mut c2s);
    expand(b"s2c", &mut s2c);
    expand(b"sas", &mut sas);
    Keys { c2s, s2c, code: format!("{:06}", u32::from_be_bytes(sas) % 1_000_000) }
}

// ── Frames ───────────────────────────────────────────────────────────────────

pub fn write_frame(w: &mut impl Write, payload: &[u8]) -> std::io::Result<()> {
    if payload.len() > MAX_FRAME {
        return Err(std::io::Error::other("frame too large"));
    }
    w.write_all(&(payload.len() as u32).to_be_bytes())?;
    w.write_all(payload)?;
    w.flush()
}

pub fn read_frame(r: &mut impl Read) -> std::io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME + 16 {
        return Err(std::io::Error::other("frame too large"));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

fn nonce(counter: u64) -> Nonce {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(&counter.to_be_bytes());
    Nonce::assume_unique_for_key(n)
}

pub struct Sealer {
    key: LessSafeKey,
    counter: u64,
}

impl Sealer {
    pub fn new(key: &[u8; 32]) -> Sealer {
        Sealer { key: LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).expect("32-byte key")), counter: 0 }
    }

    pub fn seal(&mut self, plain: &[u8]) -> Vec<u8> {
        let mut buf = plain.to_vec();
        self.key.seal_in_place_append_tag(nonce(self.counter), Aad::empty(), &mut buf).expect("seal");
        self.counter += 1;
        buf
    }

    pub fn open(&mut self, mut data: Vec<u8>) -> Option<Vec<u8>> {
        let plain = self.key.open_in_place(nonce(self.counter), Aad::empty(), &mut data).ok()?.to_vec();
        self.counter += 1;
        Some(plain)
    }
}

/// An encrypted, authenticated conversation with a peer over any byte stream.
pub struct Channel<S: Read + Write> {
    pub stream: S,
    send: Sealer,
    recv: Sealer,
    /// The peer, as it proved itself in the handshake.
    pub peer_id: String,
    pub peer_name: String,
    pub peer_key: Vec<u8>,
    /// The pairing code (shown to the user in `pair` mode).
    pub code: String,
}

impl<S: Read + Write> Channel<S> {
    pub fn send(&mut self, value: &Value) -> std::io::Result<()> {
        let sealed = self.send.seal(value.to_string().as_bytes());
        write_frame(&mut self.stream, &sealed)
    }

    pub fn recv(&mut self) -> std::io::Result<Value> {
        let frame = read_frame(&mut self.stream)?;
        let plain = self.recv.open(frame).ok_or_else(|| std::io::Error::other("bad frame"))?;
        serde_json::from_slice(&plain).map_err(|_| std::io::Error::other("bad message"))
    }
}

fn read_json(r: &mut impl Read) -> std::io::Result<Value> {
    let frame = read_frame(r)?;
    if frame.len() > 4096 {
        return Err(std::io::Error::other("hello too large"));
    }
    serde_json::from_slice(&frame).map_err(|_| std::io::Error::other("bad hello"))
}

fn field(v: &Value, k: &str) -> std::io::Result<Vec<u8>> {
    v.get(k).and_then(Value::as_str).and_then(unb64).ok_or_else(|| std::io::Error::other(format!("missing {k}")))
}

fn text(v: &Value, k: &str, max: usize) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or_default().chars().filter(|c| !c.is_control()).take(max).collect()
}

fn ephemeral() -> std::io::Result<(EphemeralPrivateKey, Vec<u8>)> {
    let private = EphemeralPrivateKey::generate(&X25519, &SystemRandom::new()).map_err(|_| std::io::Error::other("rng"))?;
    let public = private.compute_public_key().map_err(|_| std::io::Error::other("x25519"))?.as_ref().to_vec();
    Ok((private, public))
}

fn agree(private: EphemeralPrivateKey, peer: &[u8]) -> std::io::Result<Vec<u8>> {
    agreement::agree_ephemeral(private, &UnparsedPublicKey::new(&X25519, peer), |km| km.to_vec())
        .map_err(|_| std::io::Error::other("bad key"))
}

fn bad(msg: &str) -> std::io::Error {
    std::io::Error::other(msg.to_string())
}

/// Client side. `expect`: the key this peer paired with (session mode).
pub fn connect<S: Read + Write>(
    mut stream: S,
    me: &Identity,
    my_name: &str,
    mode: &str,
    expect: Option<&[u8]>,
) -> std::io::Result<Channel<S>> {
    let (eph_private, eph) = ephemeral()?;
    let hello = json!({ "hello": 1, "id": me.id(), "name": my_name, "key": b64(&me.public()), "eph": b64(&eph), "mode": mode });
    write_frame(&mut stream, hello.to_string().as_bytes())?;

    let server = read_json(&mut stream)?;
    let (key_s, eph_s, sig_s) = (field(&server, "key")?, field(&server, "eph")?, field(&server, "sig")?);
    if key_s.len() != 32 || eph_s.len() != 32 {
        return Err(bad("bad server keys"));
    }
    if server.get("id").and_then(Value::as_str) != Some(id_of(&key_s).as_str()) {
        return Err(bad("server id doesn't match its key"));
    }
    if let Some(expect) = expect {
        if expect != key_s.as_slice() {
            return Err(bad("this isn't the Mochi you paired with"));
        }
    }
    let th = transcript(&me.public(), &eph, &key_s, &eph_s);
    if !verify(&key_s, &signed("server", &th), &sig_s) {
        return Err(bad("server signature"));
    }
    write_frame(&mut stream, json!({ "sig": b64(&me.sign(&signed("client", &th))) }).to_string().as_bytes())?;
    let keys = derive(&agree(eph_private, &eph_s)?, &th);
    Ok(Channel {
        stream,
        send: Sealer::new(&keys.c2s),
        recv: Sealer::new(&keys.s2c),
        peer_id: id_of(&key_s),
        peer_name: text(&server, "name", 40),
        peer_key: key_s,
        code: keys.code,
    })
}

/// Server side. `trusted(key)` decides a `session`; a `pair` always goes on to
/// the code comparison. Returns the channel and the client's mode.
pub fn accept<S: Read + Write>(
    mut stream: S,
    me: &Identity,
    my_name: &str,
    trusted: impl Fn(&[u8]) -> bool,
) -> std::io::Result<(Channel<S>, String)> {
    let client = read_json(&mut stream)?;
    let (key_c, eph_c) = (field(&client, "key")?, field(&client, "eph")?);
    if key_c.len() != 32 || eph_c.len() != 32 {
        return Err(bad("bad client keys"));
    }
    if client.get("id").and_then(Value::as_str) != Some(id_of(&key_c).as_str()) {
        return Err(bad("client id doesn't match its key"));
    }
    let mode = client.get("mode").and_then(Value::as_str).unwrap_or_default().to_string();
    match mode.as_str() {
        "pair" => {}
        "session" if trusted(&key_c) => {}
        "session" => return Err(bad("not paired")),
        _ => return Err(bad("unknown mode")),
    }

    let (eph_private, eph) = ephemeral()?;
    let th = transcript(&key_c, &eph_c, &me.public(), &eph);
    let hello = json!({
        "hello": 1, "id": me.id(), "name": my_name, "key": b64(&me.public()), "eph": b64(&eph),
        "sig": b64(&me.sign(&signed("server", &th))),
    });
    write_frame(&mut stream, hello.to_string().as_bytes())?;

    let reply = read_json(&mut stream)?;
    if !verify(&key_c, &signed("client", &th), &field(&reply, "sig")?) {
        return Err(bad("client signature"));
    }
    let keys = derive(&agree(eph_private, &eph_c)?, &th);
    Ok((
        Channel {
            stream,
            send: Sealer::new(&keys.s2c),
            recv: Sealer::new(&keys.c2s),
            peer_id: id_of(&key_c),
            peer_name: text(&client, "name", 40),
            peer_key: key_c,
            code: keys.code,
        },
        mode,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{TcpListener, TcpStream};

    #[test]
    fn base64_round_trips() {
        for n in 0..70u8 {
            let bytes: Vec<u8> = (0..n).map(|i| i.wrapping_mul(37)).collect();
            assert_eq!(unb64(&b64(&bytes)).unwrap(), bytes);
        }
        assert_eq!(b64(b"hola"), "aG9sYQ==");
        assert!(unb64("a$b").is_none());
    }

    /// The vectors in docs/LAN.md and tests/LanWireTests.swift: both builds must
    /// derive the same keys and seal the same bytes.
    #[test]
    fn derivation_and_sealing_match_the_shared_vectors() {
        let keys = derive(&[0x11; 32], &[0x22; 32]);
        let c2s = hex(&keys.c2s);
        let s2c = hex(&keys.s2c);
        let frame = hex(&Sealer::new(&keys.c2s).seal(br#"{"t":"ping"}"#));
        println!("VECTORS c2s={c2s} s2c={s2c} code={} frame={frame}", keys.code);
        assert_eq!(c2s, VECTOR_C2S);
        assert_eq!(s2c, VECTOR_S2C);
        assert_eq!(keys.code, VECTOR_CODE);
        assert_eq!(frame, VECTOR_FRAME);
        let th = hex(&transcript(&[1; 32], &[2; 32], &[3; 32], &[4; 32]));
        assert_eq!(th, VECTOR_TH);
    }

    const VECTOR_C2S: &str = "79e710446fec5c1a25ca933ae813742df85a90d1c6dece6c53a2685334615be7";
    const VECTOR_S2C: &str = "56dc67ea8dda757573d99b394936dfbd514aef17be380a46b392d44e72ede183";
    const VECTOR_CODE: &str = "887393";
    const VECTOR_FRAME: &str = "e76f7fd2787a6fd5d917bb1df1e481fde6d915ccf46d0835a2f5d704";
    const VECTOR_TH: &str = "8571d68592452ea22865d5892957abd5b82d2ce955dde7b6affddc3c1a585dbc";

    fn pair_of_ends() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        (client, server)
    }

    #[test]
    fn a_handshake_gives_both_ends_the_same_code_and_a_working_channel() {
        let (a, b) = (Identity::generate().unwrap(), Identity::generate().unwrap());
        let (client, server) = pair_of_ends();
        let b_pub = b.public();
        let t = std::thread::spawn(move || {
            let (mut ch, mode) = accept(server, &b, "Laura", |_| false).unwrap();
            assert_eq!(mode, "pair");
            let got = ch.recv().unwrap();
            ch.send(&json!({ "echo": got })).unwrap();
            ch.code.clone()
        });
        let mut ch = connect(client, &a, "Jhon", "pair", None).unwrap();
        assert_eq!(ch.peer_name, "Laura");
        assert_eq!(ch.peer_key, b_pub);
        ch.send(&json!({ "t": "msg", "text": "hola" })).unwrap();
        assert_eq!(ch.recv().unwrap()["echo"]["text"], "hola");
        assert_eq!(t.join().unwrap(), ch.code, "both screens show the same code");
    }

    #[test]
    fn a_session_needs_a_paired_key_on_both_sides() {
        let (a, b, mallory) = (Identity::generate().unwrap(), Identity::generate().unwrap(), Identity::generate().unwrap());
        // The server doesn't know the client.
        let (client, server) = pair_of_ends();
        let t = std::thread::spawn(move || accept(server, &b, "B", |_| false).map(|_| ()));
        assert!(connect(client, &a, "A", "session", None).is_err());
        assert!(t.join().unwrap().is_err());
        // The client expects another key than the one answering.
        let (client, server) = pair_of_ends();
        let expected = Identity::generate().unwrap().public();
        let t = std::thread::spawn(move || {
            let _ = accept(server, &mallory, "B", |_| true);
        });
        assert!(connect(client, &a, "A", "session", Some(&expected)).is_err());
        t.join().unwrap();
    }

    #[test]
    fn a_tampered_or_replayed_frame_is_refused() {
        let keys = derive(&[7; 32], &[9; 32]);
        let mut tx = Sealer::new(&keys.c2s);
        let mut rx = Sealer::new(&keys.c2s);
        let first = tx.seal(b"one");
        let mut flipped = first.clone();
        flipped[0] ^= 1;
        assert!(Sealer::new(&keys.c2s).open(flipped).is_none());
        assert_eq!(rx.open(first.clone()).unwrap(), b"one");
        assert!(rx.open(first).is_none(), "the counter moved on: a replay fails");
    }
}
