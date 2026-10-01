import Foundation
import CryptoKit
import Darwin

// MARK: - LAN wire format (docs/LAN.md) — the macOS side of windows/src-tauri/src/lan/wire.rs
// Identity, handshake, keys and encrypted frames over a blocking socket. No app
// dependencies: tests/LanWireTests.swift compiles this file alone and checks it
// against the same vectors as the Windows build.

enum LanWire {
    static let proto = Data("coucou-lan-v1".utf8)
    static let maxFrame = 256 * 1024

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Identity

    /// First 8 bytes of SHA-256(public key), lowercase hex.
    static func id(of publicKey: Data) -> String {
        hex(Data(SHA256.hash(data: publicKey)).prefix(8))
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return hex(Data(b))
    }

    // MARK: Keys

    static func transcript(keyC: Data, ephC: Data, keyS: Data, ephS: Data) -> Data {
        Data(SHA256.hash(data: proto + keyC + ephC + keyS + ephS))
    }

    static func signed(_ role: String, _ th: Data) -> Data {
        proto + Data(" \(role)".utf8) + th
    }

    struct Keys: Equatable {
        let c2s: Data
        let s2c: Data
        /// The six digits both users compare when pairing.
        let code: String
    }

    static func derive(shared: Data, th: Data) -> Keys {
        func expand(_ info: String, _ n: Int) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: th,
                                   info: Data(info.utf8), outputByteCount: n)
                .withUnsafeBytes { Data($0) }
        }
        let sas = expand("sas", 4)
        let n = sas.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Keys(c2s: expand("c2s", 32), s2c: expand("s2c", 32), code: String(format: "%06u", n % 1_000_000))
    }

    // MARK: Sealing — AES-256-GCM, nonce = 4 zero bytes ‖ 8-byte big-endian counter

    final class Sealer {
        private let key: SymmetricKey
        private var counter: UInt64 = 0
        init(key: Data) { self.key = SymmetricKey(data: key) }

        private func nonce() throws -> AES.GCM.Nonce {
            var n = Data(count: 4)
            withUnsafeBytes(of: counter.bigEndian) { n.append(contentsOf: $0) }
            return try AES.GCM.Nonce(data: n)
        }

        func seal(_ plain: Data) throws -> Data {
            let box = try AES.GCM.seal(plain, using: key, nonce: nonce())
            counter += 1
            return box.ciphertext + box.tag
        }

        func open(_ data: Data) throws -> Data {
            guard data.count >= 16 else { throw Failure("bad frame") }
            let box = try AES.GCM.SealedBox(nonce: nonce(), ciphertext: data.dropLast(16), tag: data.suffix(16))
            let plain = try AES.GCM.open(box, using: key)
            counter += 1
            return plain
        }
    }

    // MARK: Frames over a blocking socket

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { throw Failure("connection closed") }
                off += n
            }
        }
    }

    static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data(count: count)
        var off = 0
        while off < count {
            let n = out.withUnsafeMutableBytes { raw in Darwin.recv(fd, raw.baseAddress! + off, count - off, 0) }
            if n <= 0 { throw Failure("connection closed") }
            off += n
        }
        return out
    }

    static func writeFrame(_ fd: Int32, _ payload: Data) throws {
        guard payload.count <= maxFrame else { throw Failure("frame too large") }
        var len = UInt32(payload.count).bigEndian
        try writeAll(fd, Data(bytes: &len, count: 4) + payload)
    }

    static func readFrame(_ fd: Int32) throws -> Data {
        let len = try readExact(fd, 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard Int(len) <= maxFrame + 16 else { throw Failure("frame too large") }
        return try readExact(fd, Int(len))
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("bad message") }
        return o
    }

    static func cleanText(_ any: Any?, _ max: Int) -> String {
        String(((any as? String) ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init).prefix(max))
    }

    // MARK: Channel

    /// An encrypted, authenticated conversation with a peer.
    final class Channel {
        let fd: Int32
        private let sender: Sealer
        private let receiver: Sealer
        let peerId: String
        let peerName: String
        let peerKey: Data
        let code: String

        init(fd: Int32, send: Data, recv: Data, peerKey: Data, peerName: String, code: String) {
            self.fd = fd
            self.sender = Sealer(key: send)
            self.receiver = Sealer(key: recv)
            self.peerKey = peerKey
            self.peerId = LanWire.id(of: peerKey)
            self.peerName = peerName
            self.code = code
        }

        func send(_ message: [String: Any]) throws {
            try LanWire.writeFrame(fd, sender.seal(LanWire.json(message)))
        }

        func recv() throws -> [String: Any] {
            try LanWire.object(receiver.open(LanWire.readFrame(fd)))
        }

        func setTimeout(_ seconds: Int) {
            var tv = timeval(tv_sec: seconds, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private static func field(_ o: [String: Any], _ k: String) throws -> Data {
        guard let s = o[k] as? String, let d = Data(base64Encoded: s) else { throw Failure("missing \(k)") }
        return d
    }

    private static func readHello(_ fd: Int32) throws -> [String: Any] {
        let frame = try readFrame(fd)
        guard frame.count <= 4096 else { throw Failure("hello too large") }
        return try object(frame)
    }

    /// Client side. `expect`: the key this peer paired with (session mode).
    static func connect(fd: Int32, me: Curve25519.Signing.PrivateKey, name: String, mode: String,
                        expect: Data?) throws -> Channel {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let myKey = me.publicKey.rawRepresentation
        let ephPub = eph.publicKey.rawRepresentation
        try writeFrame(fd, json(["hello": 1, "id": id(of: myKey), "name": name, "key": myKey.base64EncodedString(),
                                 "eph": ephPub.base64EncodedString(), "mode": mode]))
        let server = try readHello(fd)
        let keyS = try field(server, "key"), ephS = try field(server, "eph"), sigS = try field(server, "sig")
        guard keyS.count == 32, ephS.count == 32 else { throw Failure("bad server keys") }
        guard server["id"] as? String == id(of: keyS) else { throw Failure("server id doesn't match its key") }
        if let expect, expect != keyS { throw Failure("this isn't the Mochi you paired with") }
        let th = transcript(keyC: myKey, ephC: ephPub, keyS: keyS, ephS: ephS)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: keyS).isValidSignature(sigS, for: signed("server", th))
        else { throw Failure("server signature") }
        try writeFrame(fd, json(["sig": try me.signature(for: signed("client", th)).base64EncodedString()]))
        let shared = try eph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephS))
        let keys = derive(shared: shared.withUnsafeBytes { Data($0) }, th: th)
        return Channel(fd: fd, send: keys.c2s, recv: keys.s2c, peerKey: keyS,
                       peerName: cleanText(server["name"], 40), code: keys.code)
    }

    /// Server side. `trusted(key)` decides a `session`; a `pair` always goes on
    /// to the code comparison.
    static func accept(fd: Int32, me: Curve25519.Signing.PrivateKey, name: String,
                       trusted: (Data) -> Bool) throws -> (Channel, String) {
        let client = try readHello(fd)
        let keyC = try field(client, "key"), ephC = try field(client, "eph")
        guard keyC.count == 32, ephC.count == 32 else { throw Failure("bad client keys") }
        guard client["id"] as? String == id(of: keyC) else { throw Failure("client id doesn't match its key") }
        let mode = client["mode"] as? String ?? ""
        switch mode {
        case "pair": break
        case "session" where trusted(keyC): break
        case "session": throw Failure("not paired")
        default: throw Failure("unknown mode")
        }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let myKey = me.publicKey.rawRepresentation
        let ephPub = eph.publicKey.rawRepresentation
        let th = transcript(keyC: keyC, ephC: ephC, keyS: myKey, ephS: ephPub)
        try writeFrame(fd, json(["hello": 1, "id": id(of: myKey), "name": name, "key": myKey.base64EncodedString(),
                                 "eph": ephPub.base64EncodedString(),
                                 "sig": try me.signature(for: signed("server", th)).base64EncodedString()]))
        let reply = try readHello(fd)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: keyC).isValidSignature(field(reply, "sig"), for: signed("client", th))
        else { throw Failure("client signature") }
        let shared = try eph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephC))
        let keys = derive(shared: shared.withUnsafeBytes { Data($0) }, th: th)
        return (Channel(fd: fd, send: keys.s2c, recv: keys.c2s, peerKey: keyC,
                        peerName: cleanText(client["name"], 40), code: keys.code), mode)
    }

    /// Only a name: any path is dropped, and characters a file system refuses.
    static func safeFileName(_ raw: String) -> String {
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(base.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !"<>:\"|?*".unicodeScalars.contains($0) }
            .map(Character.init).prefix(120))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "file" : cleaned
    }
}
