// Sim-only control channel: drive the real input path from the Mac instead of
// baking a scenario into a -vrdev.*Test scene. Newline-delimited text commands
// on 127.0.0.1:7070 (-vrdev.ctlPort to change). The sim shares the Mac's
// network stack, so native/vrctl (or `nc 127.0.0.1 7070`) reaches it.
//
// Buttons are held (down/up) or tapped (held for a few polls, so the game's
// edge detection sees a press then a release). They set the same
// GameInput.State fields a controller or keyboard would, after the device poll.
#if targetEnvironment(simulator)
import Foundation
import Network

final class SimControl: @unchecked Sendable {
    static let shared = SimControl()

    /// Where the pointer aims while a panel is open. WorldSession turns it into
    /// a point on the panel and points the real ray at it.
    enum Aim: Equatable {
        case slot(Int)                      // index into the laid-out panel slots
        case listSlot(String, Int)          // e.g. "main 3", "craft 0"
        case widget(String)                 // a button / field by name or label
        case uv(Float, Float)               // panel-local metres from the centre
        case key(String)                    // a spatial keyboard key id
    }

    private let lock = NSLock()
    private var held: Set<String> = []
    private var pulses: [String: Int] = [:]     // button -> polls left
    private var sticks: [String: SIMD2<Float>] = [:]   // "l" / "r"
    private var yawDelta: Float = 0
    private var typed: [GameInput.TypedKey] = []
    private var chats: [String] = []
    private var _pitchDeg: Float = 0
    private var _aim: Aim? = nil
    private var queries: [(String, (String) -> Void)] = []
    private var listener: NWListener?

    var pitchDeg: Float { lock.lock(); defer { lock.unlock() }; return _pitchDeg }
    var aim: Aim? { lock.lock(); defer { lock.unlock() }; return _aim }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { return }
        let raw = UserDefaults.standard.integer(forKey: "vrdev.ctlPort")
        let port = NWEndpoint.Port(rawValue: UInt16(raw > 0 ? raw : 7070))!
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port) else {
            print("[simctl] could not listen on \(port)"); fflush(stdout); return
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { st in print("[simctl] listener \(st)"); fflush(stdout) }
        l.start(queue: DispatchQueue(label: "simctl"))
        listener = l
        print("[simctl] listening on 127.0.0.1:\(port)"); fflush(stdout)
    }

    private func serve(_ c: NWConnection) {
        let q = DispatchQueue(label: "simctl.conn")
        c.start(queue: q)
        var pending = ""
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
                pending += String(decoding: d ?? Data(), as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]).trimmingCharacters(in: .whitespaces)
                    pending = String(pending[pending.index(after: nl)...])
                    guard !line.isEmpty else { continue }
                    let reply = self?.handle(line) ?? "err gone"
                    c.send(content: (reply + "\n").data(using: .utf8), completion: .idempotent)
                }
                if done || err != nil { c.cancel() } else { read() }
            }
        }
        read()
    }

    static let help = """
        down <btn> | up <btn> | tap <btn> [polls] | release
        stick l|r <x> <y>        (held until changed; stick l 0 0 to centre)
        turn <deg> | pitch <deg> (turn is relative body yaw; pitch is absolute head pitch)
        aim slot <n> | aim <list> <index> | aim widget <name> | aim uv <u> <v> | aim key <id> | aim off
        type <text> | chat <text>
        state | slots | widgets  (JSON, answered on the next game tick)
        buttons: w a s d space shift e f r p i q esc enter shift-enter 1-9 b n left right
                 rt lt rgrip lgrip square triangle circle options create l3 r3
        """

    /// One command line -> one reply line. Runs on the listener queue.
    func handle(_ line: String) -> String {
        var a = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let cmd = a.isEmpty ? "" : a.removeFirst()
        let rest = line.drop(while: { $0 == " " }).dropFirst(cmd.count).drop(while: { $0 == " " })
        switch cmd {
        case "state", "slots", "widgets":
            return query(cmd)
        case "help":
            return Self.help.replacingOccurrences(of: "\n", with: " / ")
        default: break
        }
        lock.lock(); defer { lock.unlock() }
        switch cmd {
        case "down" where a.count == 1:  held.insert(a[0])
        case "up" where a.count == 1:    held.remove(a[0])
        case "tap" where a.count >= 1:   pulses[a[0]] = max(1, Int(a.count > 1 ? a[1] : "4") ?? 4)
        case "release":                  held.removeAll(); pulses.removeAll(); sticks.removeAll()
        case "stick" where a.count == 3 && (a[0] == "l" || a[0] == "r"):
            sticks[a[0]] = SIMD2(Float(a[1]) ?? 0, Float(a[2]) ?? 0)
        case "turn" where a.count == 1:  yawDelta += (Float(a[0]) ?? 0) * .pi / 180
        case "pitch" where a.count == 1: _pitchDeg = Float(a[0]) ?? 0
        case "aim" where a.first == "off": _aim = nil
        case "aim" where a.count == 2 && a[0] == "slot": _aim = Int(a[1]).map { .slot($0) }
        case "aim" where a.count >= 2 && a[0] == "widget": _aim = .widget(a.dropFirst().joined(separator: " "))
        case "aim" where a.count == 2 && a[0] == "key": _aim = .key(a[1])
        case "aim" where a.count == 3 && a[0] == "uv": _aim = .uv(Float(a[1]) ?? 0, Float(a[2]) ?? 0)
        case "aim" where a.count == 2: _aim = Int(a[1]).map { .listSlot(a[0], $0) }
        case "type":
            for ch in rest { typed.append(ch == "\u{8}" ? .backspace : .char(ch)) }
        case "chat" where !rest.isEmpty: chats.append(String(rest))
        default:
            return "err unknown: \(line)"
        }
        return "ok"
    }

    /// Block the connection until the game tick answers (or 3 s pass).
    private func query(_ what: String) -> String {
        let sem = DispatchSemaphore(value: 0)
        var answer = "err no answer (is a world session ticking?)"
        lock.lock()
        queries.append((what, { answer = $0; sem.signal() }))
        lock.unlock()
        _ = sem.wait(timeout: .now() + 3)
        return answer
    }

    /// WorldSession's tick: answer queued queries and send queued chat.
    func drain(answer: (String) -> String, sendChat: (String) -> Void) {
        lock.lock()
        let qs = queries; queries = []
        let cs = chats; chats = []
        lock.unlock()
        for (what, reply) in qs { reply(answer(what)) }
        for c in cs { sendChat(c) }
    }

    /// End of GameInput.poll(): OR the scripted buttons into the device state.
    func apply(_ s: inout GameInput.State, textEntry: Bool) {
        lock.lock(); defer { lock.unlock() }
        var k = held
        for (key, n) in pulses { k.insert(key); pulses[key] = n > 1 ? n - 1 : nil }
        if !typed.isEmpty { s.typed += typed; typed = [] }
        if k.contains("esc") { s.escape = true; s.cancel = true; if !textEntry { s.koganeMenu = true } }
        if k.contains("enter") { s.enterPrimary = true; s.menuSelect = true }
        if k.contains("shift-enter") { s.enterSecondary = true; s.menuSelect = true }
        if textEntry { return }   // same as the keyboard: typing doesn't drive the game
        if let l = sticks["l"] {
            if l.x != 0 { s.move.x = l.x }
            if l.y != 0 { s.move.y = l.y; s.menuNavY = l.y }
        }
        if let r = sticks["r"] {
            if r.x != 0 { s.turn = r.x }
            if r.y != 0 && abs(r.y) > abs(s.menuNavY) { s.menuNavY = r.y }
        }
        if k.contains("w") { s.move.y = 1; s.menuNavY = 1 }
        if k.contains("s") { s.move.y = -1; s.menuNavY = -1 }
        if k.contains("a") { s.move.x = -1 }
        if k.contains("d") { s.move.x = 1 }
        if k.contains("left") { s.turn = -1 }
        if k.contains("right") { s.turn = 1 }
        if k.contains("space") || k.contains("lt") { s.jump = true }
        if k.contains("lt") || k.contains("rt") { s.menuSelect = true }
        if k.contains("shift") || k.contains("l3") { s.sneak = true }
        if k.contains("e") || k.contains("lgrip") { s.fast = true }
        if k.contains("f") || k.contains("rt") { s.dig = true }
        if k.contains("f") { s.menuSelect = true }
        if k.contains("r") || k.contains("rgrip") { s.place = true }
        if k.contains("p") || k.contains("create") { s.photo = true }
        if k.contains("options") { s.cancel = true; s.koganeMenu = true }
        if k.contains("i") || k.contains("circle") { s.inventory = true }
        if k.contains("q") { s.drop = true }
        if k.contains("b") || k.contains("square") { s.hotbarPrev = true }
        if k.contains("n") || k.contains("triangle") { s.hotbarNext = true }
        if k.contains("r3") { s.dismissChat = true }
        if let n = (1...9).first(where: { k.contains("\($0)") }) { s.hotbarSlot = n - 1 }
        if yawDelta != 0 { s.lookYaw += yawDelta; yawDelta = 0 }
    }
}
#endif
