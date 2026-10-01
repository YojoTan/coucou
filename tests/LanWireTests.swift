import Foundation
import CryptoKit
import Darwin

// The LAN wire vectors shared with windows/src-tauri/src/lan/wire.rs: both builds
// must derive the same keys and seal the same bytes, or they can't talk.

@main
struct LanWireTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if ok { print("ok  \(what)") } else { print("FAIL \(what)"); failures += 1 }
    }

    static func main() throws {
        // Unbuffered, so a crash still shows the last check that ran.
        setvbuf(stdout, nil, _IONBF, 0)
        let keys = LanWire.derive(shared: Data(repeating: 0x11, count: 32), th: Data(repeating: 0x22, count: 32))
        check(LanWire.hex(keys.c2s) == "79e710446fec5c1a25ca933ae813742df85a90d1c6dece6c53a2685334615be7", "c2s matches Windows")
        check(LanWire.hex(keys.s2c) == "56dc67ea8dda757573d99b394936dfbd514aef17be380a46b392d44e72ede183", "s2c matches Windows")
        check(keys.code == "887393", "pairing code matches Windows")
        let frame = try LanWire.Sealer(key: keys.c2s).seal(Data(#"{"t":"ping"}"#.utf8))
        check(LanWire.hex(frame) == "e76f7fd2787a6fd5d917bb1df1e481fde6d915ccf46d0835a2f5d704", "sealed frame matches Windows")
        let th = LanWire.transcript(keyC: Data(repeating: 1, count: 32), ephC: Data(repeating: 2, count: 32),
                                    keyS: Data(repeating: 3, count: 32), ephS: Data(repeating: 4, count: 32))
        check(LanWire.hex(th) == "8571d68592452ea22865d5892957abd5b82d2ce955dde7b6affddc3c1a585dbc", "transcript matches Windows")

        // A replay or a flipped bit is refused.
        let rx = LanWire.Sealer(key: keys.c2s)
        check((try? rx.open(frame)) != nil, "a frame opens once")
        check((try? rx.open(frame)) == nil, "a replay is refused")
        var flipped = frame
        flipped[0] ^= 1
        check((try? LanWire.Sealer(key: keys.c2s).open(flipped)) == nil, "a tampered frame is refused")

        check(LanWire.safeFileName("../../etc/passwd") == "passwd", "received names lose their path")
        check(LanWire.safeFileName("..") == "file", "an empty name becomes file")

        // A full handshake over a socket pair: same code on both ends, a working channel.
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        let a = Curve25519.Signing.PrivateKey(), b = Curve25519.Signing.PrivateKey()
        let serverFD = fds[1]
        let result = ServerBox()
        let done = DispatchSemaphore(value: 0)
        // A @Sendable closure: not tied to main()'s actor, so it may run elsewhere.
        DispatchQueue.global().async { @Sendable in
            serverSide(fd: serverFD, key: b, result: result)
            done.signal()
        }
        let ch = try LanWire.connect(fd: fds[0], me: a, name: "Jhon", mode: "pair", expect: nil)
        try ch.send(["t": "msg", "text": "hola"])
        let echo = try ch.recv()
        done.wait()
        check(echo["echo"] as? String == "hola", "the channel carries messages both ways")
        check(result.code == ch.code && result.mode == "pair", "both ends show the same code")
        check(ch.peerName == "Laura" && ch.peerKey == b.publicKey.rawRepresentation, "the peer is who it proved to be")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("all LAN wire tests passed")
    }
}

nonisolated func serverSide(fd: Int32, key: Curve25519.Signing.PrivateKey, result: ServerBox) {
    if let (ch, mode) = try? LanWire.accept(fd: fd, me: key, name: "Laura", trusted: { _ in false }),
       let got = try? ch.recv() {
        try? ch.send(["echo": got["text"] as? String ?? ""])
        result.set(code: ch.code, mode: mode)
    }
}

final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _code = "", _mode = ""
    func set(code: String, mode: String) { lock.withLock { _code = code; _mode = mode } }
    var code: String { lock.withLock { _code } }
    var mode: String { lock.withLock { _mode } }
}
