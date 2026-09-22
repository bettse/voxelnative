import Foundation
import Network
import Darwin   // BSD socket: NWConnection can't pin a local UDP port, and re-binding our own previous port is how we close our own stale session (see connect())

/// The Luanti engine's network transport, reimplemented so this client can
/// talk to a stock Luanti/VoxeLibre game server. Luanti runs its own
/// reliable-UDP protocol ("mtp", src/network/connection.cpp): a base header,
/// original/split/reliable/control packet kinds, per-channel sequence
/// numbers, ACKs, resends, split-packet reassembly and keepalive pings. This
/// is the client half of that, the same thing the official desktop client
/// implements. Originally ported via luanti_connection.gd. Game messages
/// surface via `onMessage(opcode, payload)`; nothing above this layer sees
/// raw packets.
public final class Connection {
    // Callbacks (called from poll(), i.e. the caller's thread).
    public var onConnected: ((Int) -> Void)?
    public var onMessage: ((Int, Data) -> Void)?
    public var onDisconnected: ((String) -> Void)?

    static let PROTOCOL_ID = 0x4F457403
    static let CHANNEL_COUNT = 3
    static let TYPE_CONTROL = 0, TYPE_ORIGINAL = 1, TYPE_SPLIT = 2, TYPE_RELIABLE = 3
    static let CTRL_ACK = 0, CTRL_SET_PEER_ID = 1, CTRL_PING = 2, CTRL_DISCO = 3
    // Same values as the engine's connection.h: SEQNUM_INITIAL 65500, 0x8000
    // receive window, 512-byte MTU-safe packets, 0.5 s resend base, 5 s ping /
    // 30 s peer timeout.
    static let BASE_HEADER_SIZE = 7
    static let SEQNUM_INITIAL = 65500, SEQNUM_MAX = 65535
    static let MAX_PACKET_SIZE = 512
    static let RECEIVE_WINDOW = 0x8000
    static let SEND_WINDOW = 64
    static let RESEND_TIMEOUT = 0.5, MAX_RESENDS = 12
    static let PING_INTERVAL = 5.0, PEER_TIMEOUT = 30.0, SPLIT_TIMEOUT = 30.0
    // (peer id, local UDP port) of OUR last connection, so the next launch can
    // send the DISCO a crashed session never sent (see connect()).
    static let kPrevPeerId = "net.prevPeerId", kPrevLocalPort = "net.prevLocalPort"

    final class Channel {
        var nextIncomingSeq = SEQNUM_INITIAL
        var nextOutgoingSeq = SEQNUM_INITIAL
        var nextSplitSeq = SEQNUM_INITIAL
        var incomingReliables: [Int: Data] = [:]
        var outgoingUnacked: [Int: (packet: Data, time: Double, tries: Int)] = [:]
        var outgoingQueue: [Data] = []
        var incomingSplits: [Int: (count: Int, chunks: [Int: Data], reliable: Bool, time: Double)] = [:]
    }

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "voxel.udp")
    private var channels: [Channel] = (0..<3).map { _ in Channel() }
    private let recvLock = NSLock()
    private var recvQueue: [Data] = []

    public private(set) var peerId = 0
    public private(set) var isConnected = false
    private var connecting = false
    private var time = 0.0
    private var lastReceived = 0.0
    private var lastSent = 0.0
    private var connectStarted = 0.0
    /// The handshake packet, held back until `helloAt` when this connect had
    /// to close a stale session of ours first (see connect()).
    private var pendingHello: Data?
    private var helloAt = 0.0
    /// How long the goodbye for a stale session gets before our new handshake.
    /// The server removes the old player on its next step; a join that lands in
    /// that same step ran VoxeLibre's on_joinplayer against a half-removed
    /// player (vl_legacy: "attempt to index local 'inv' (a nil value)") and
    /// crashed our local dev server (tools/server.sh) twice when the sim relaunched
    /// over a still-live session (a VoxeLibre on_joinplayer bug, but avoidable).
    static let STALE_GOODBYE_GRACE = 1.0

    public init() {}

    public func connect(host: String, port: UInt16) {
        // Reset transport state so a reconnect (reused Connection) starts clean:
        // the handshake must go out with peer id 0 and fresh channels, else the
        // server sees a stale peer id and never answers.
        conn?.cancel()   // drop any previous NWConnection so its receive loop can't push stale datagrams (F3)
        peerId = 0
        isConnected = false
        channels = (0..<Self.CHANNEL_COUNT).map { _ in Channel() }
        recvLock.lock(); recvQueue.removeAll(); recvLock.unlock()
        // Stale-session cleanup: if our OWN previous connection died without a
        // goodbye (crash/kill/in-session reconnect), the server still holds that
        // peer -- and our player name -- for its peer timeout (~30 s), so a
        // relaunch is refused with "already connected". Luanti's connection.cpp
        // resolves an incoming datagram's peer from the sender's address, so a
        // CONTROLTYPE_DISCO only ends the session whose socket actually sent it:
        // we re-bind OUR saved local port and send the goodbye the crashed
        // process never got to send. Nothing here can affect another client's
        // peer. Cleared on a clean disconnect.
        let d = UserDefaults.standard
        let prevPeer = d.integer(forKey: Self.kPrevPeerId)
        let prevPort = UInt16(exactly: d.integer(forKey: Self.kPrevLocalPort)) ?? 0
        // NWConnection won't pin a UDP local port (it ignores
        // requiredLocalEndpoint), so the DISCO goes out on a one-shot BSD socket
        // bound to our previous port. The main transport stays NWConnection on a
        // fresh port; the fresh handshake is fine once the name is freed.
        var saidGoodbye = false
        if prevPeer != 0, prevPort != 0 {
            saidGoodbye = Self.sendDiscoForOwnStalePeer(host: host, serverPort: port, localPort: prevPort, peerId: prevPeer)
        }
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        conn = c
        // Persist this connection's actual local port (@Sendable handler: no self).
        c.stateUpdateHandler = { state in
            if case .ready = state, case let .hostPort(_, p)? = c.currentPath?.localEndpoint {
                UserDefaults.standard.set(Int(p.rawValue), forKey: Self.kPrevLocalPort)
            }
        }
        c.start(queue: queue)
        receiveNext()
        connecting = true
        connectStarted = time
        lastReceived = time
        // Same first packet as the engine: an empty reliable original, peer id 0.
        var pkt = baseHeader(channel: 0)
        pkt.append(UInt8(Self.TYPE_RELIABLE)); appendU16(&pkt, Self.SEQNUM_INITIAL)
        pkt.append(UInt8(Self.TYPE_ORIGINAL))
        channels[0].nextOutgoingSeq = (Self.SEQNUM_INITIAL + 1) & 0xFFFF
        if saidGoodbye {
            // Give the server a step to finish removing the old player before
            // we join as the same name (STALE_GOODBYE_GRACE); poll() sends it.
            pendingHello = pkt; helloAt = time + Self.STALE_GOODBYE_GRACE
        } else {
            pendingHello = nil
            sendHello(pkt)
        }
    }

    private func sendHello(_ pkt: Data) {
        // Track it for reliable resend (F4): this is the packet that elicits
        // SET_PEER_ID, so if it's lost on a flaky reconnect we must resend it at
        // RESEND_TIMEOUT instead of stalling ~10s until the connect timeout. The
        // server's ack clears it from outgoingUnacked.
        channels[0].outgoingUnacked[Int(Self.SEQNUM_INITIAL)] = (pkt, time, 1)
        sendRaw(pkt)
    }

    public func disconnect(_ reason: String = "client disconnect") {
        // A clean goodbye frees our name on the server now, so next launch has
        // no stale peer of ours to close: clear the saved peer id (keep the port).
        UserDefaults.standard.removeObject(forKey: Self.kPrevPeerId)
        guard isConnected || connecting, let c = conn else { finish(reason); return }
        var pkt = baseHeader(channel: 0)
        pkt.append(UInt8(Self.TYPE_CONTROL)); pkt.append(UInt8(Self.CTRL_DISCO))
        isConnected = false; connecting = false
        conn = nil
        // Cancel only AFTER the DISCO is handed to the network stack, otherwise
        // cancel() drops the queued packet and the server never learns we left
        // (so it holds our name until the ~15s peer timeout).
        c.send(content: pkt, completion: .contentProcessed { [weak self] _ in
            c.cancel()
            self?.onDisconnected?(reason)
        })
    }

    private func finish(_ reason: String) {
        let was = isConnected || connecting
        isConnected = false; connecting = false; pendingHello = nil
        conn?.cancel(); conn = nil
        if was { onDisconnected?(reason) }
    }

    private func receiveNext() {
        conn?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.recvLock.lock(); self.recvQueue.append(data); self.recvLock.unlock()
            }
            if error == nil { self.receiveNext() }
        }
    }

    private func takeReceived() -> [Data] {
        recvLock.lock(); let got = recvQueue; recvQueue = []; recvLock.unlock(); return got
    }

    /// One game message. Channel/reliability from the routing table unless given.
    public func sendMessage(_ opcode: Int, _ payload: Data, channel: Int = -1, reliable: Bool = true) {
        var ch = channel, rel = reliable
        if ch < 0 { let r = Op.toserverRouting[opcode] ?? (0, true); ch = r.channel; rel = r.reliable }
        var data = Data(); appendU16(&data, opcode); data.append(payload)
        let channelObj = channels[ch]
        let maxOriginal = Self.MAX_PACKET_SIZE - Self.BASE_HEADER_SIZE - 1 - (rel ? 3 : 0)
        if data.count <= maxOriginal {
            var inner = Data([UInt8(Self.TYPE_ORIGINAL)]); inner.append(data)
            sendInner(channelObj, ch, inner, rel); return
        }
        let chunkMax = Self.MAX_PACKET_SIZE - Self.BASE_HEADER_SIZE - 7 - (rel ? 3 : 0)
        let count = (data.count + chunkMax - 1) / chunkMax
        let splitSeq = channelObj.nextSplitSeq
        channelObj.nextSplitSeq = (channelObj.nextSplitSeq + 1) & 0xFFFF
        for i in 0..<count {
            var inner = Data([UInt8(Self.TYPE_SPLIT)])
            appendU16(&inner, splitSeq); appendU16(&inner, count); appendU16(&inner, i)
            let lo = i * chunkMax, hi = min((i + 1) * chunkMax, data.count)
            inner.append(data.subdata(in: (data.startIndex + lo)..<(data.startIndex + hi)))
            sendInner(channelObj, ch, inner, rel)
        }
    }

    private func sendInner(_ ch: Channel, _ channel: Int, _ inner: Data, _ reliable: Bool) {
        var pkt = baseHeader(channel: channel)
        if reliable {
            let seq = ch.nextOutgoingSeq
            ch.nextOutgoingSeq = (ch.nextOutgoingSeq + 1) & 0xFFFF
            pkt.append(UInt8(Self.TYPE_RELIABLE)); appendU16(&pkt, seq); pkt.append(inner)
            if ch.outgoingUnacked.count >= Self.SEND_WINDOW || !ch.outgoingQueue.isEmpty {
                ch.outgoingQueue.append(pkt)
            } else {
                ch.outgoingUnacked[seq] = (pkt, time, 1); sendRaw(pkt)
            }
        } else {
            pkt.append(inner); sendRaw(pkt)
        }
    }

    private func sendAck(_ channel: Int, _ seq: Int) {
        var pkt = baseHeader(channel: channel)
        pkt.append(UInt8(Self.TYPE_CONTROL)); pkt.append(UInt8(Self.CTRL_ACK)); appendU16(&pkt, seq)
        sendRaw(pkt)
    }

    public func sendPing() {
        var pkt = baseHeader(channel: 0)
        pkt.append(UInt8(Self.TYPE_CONTROL)); pkt.append(UInt8(Self.CTRL_PING))
        sendRaw(pkt)
    }

    /// Call periodically. Drains received datagrams, handles resends and pings.
    public func poll(_ delta: Double) {
        time += delta
        if !(isConnected || connecting) { return }
        if let hello = pendingHello, time >= helloAt { pendingHello = nil; sendHello(hello) }
        for pkt in takeReceived() {
            lastReceived = time
            handleDatagram(pkt)
            if !(isConnected || connecting) { return }
        }
        if connecting && time - connectStarted > 10.0 { finish("no answer from server"); return }
        if time - lastReceived > Self.PEER_TIMEOUT { finish("timed out"); return }
        for c in 0..<Self.CHANNEL_COUNT {
            let ch = channels[c]
            // Collect due resends first, then mutate: modifying a Dictionary
            // while iterating it traps. (Loopback never times out, so the sim
            // never hit this; real WiFi with lagging acks does.)
            var toResend: [Int] = []
            for (seq, entry) in ch.outgoingUnacked {
                let timeout = Self.RESEND_TIMEOUT * min(pow(1.5, Double(entry.tries - 1)), 8.0)
                if time - entry.time >= timeout {
                    if entry.tries >= Self.MAX_RESENDS { finish("server stopped acknowledging"); return }
                    toResend.append(seq)
                }
            }
            for seq in toResend {
                guard let entry = ch.outgoingUnacked[seq] else { continue }
                ch.outgoingUnacked[seq] = (entry.packet, time, entry.tries + 1)
                sendRaw(entry.packet)
            }
            flushQueue(ch)
            // Expire stale partial splits, reliable ones too: a reliable split that
            // announces N chunks but never completes (malformed server, wrong chunk
            // count) would otherwise sit in the map forever. 30s is well past any
            // real in-progress transfer.
            let staleSplits = ch.incomingSplits.filter { time - $0.value.time > Self.SPLIT_TIMEOUT }.map { $0.key }
            for ss in staleSplits { ch.incomingSplits.removeValue(forKey: ss) }
        }
        if isConnected && time - lastSent > Self.PING_INTERVAL { sendPing() }
    }

    private func flushQueue(_ ch: Channel) {
        while !ch.outgoingQueue.isEmpty && ch.outgoingUnacked.count < Self.SEND_WINDOW {
            let pkt = ch.outgoingQueue.removeFirst()
            let seq = readU16(pkt, Self.BASE_HEADER_SIZE + 1)
            ch.outgoingUnacked[seq] = (pkt, time, 1); sendRaw(pkt)
        }
    }

    /// Hand a datagram to the receive path directly instead of via the socket,
    /// so reliability/split/reordering/wraparound are unit-testable with no
    /// server. Test-only seam; ACKs go to a nil connection (harmless no-op).
    func ingestDatagramForTesting(_ pkt: Data) { handleDatagram(pkt) }

    private func handleDatagram(_ pkt: Data) {
        guard pkt.count >= Self.BASE_HEADER_SIZE + 1 else { return }
        guard readU32(pkt, 0) == Self.PROTOCOL_ID else { return }
        let channel = Int(pkt[pkt.startIndex + 6])
        guard channel < Self.CHANNEL_COUNT else { return }
        handlePacket(channel, sliced(pkt, Self.BASE_HEADER_SIZE), false)
    }

    private func handlePacket(_ channel: Int, _ data: Data, _ insideReliable: Bool) {
        guard !data.isEmpty else { return }
        let ch = channels[channel]
        switch Int(data[data.startIndex]) {
        case Self.TYPE_CONTROL:
            guard data.count >= 2 else { return }
            switch Int(data[data.startIndex + 1]) {
            case Self.CTRL_ACK:
                if data.count >= 4 { ch.outgoingUnacked.removeValue(forKey: readU16(data, 2)) }
            case Self.CTRL_SET_PEER_ID:
                if data.count >= 4 {
                    peerId = readU16(data, 2)
                    UserDefaults.standard.set(peerId, forKey: Self.kPrevPeerId)   // so a crashed session can still be closed next launch
                    if connecting { connecting = false; isConnected = true; onConnected?(peerId) }
                }
            case Self.CTRL_PING: break
            case Self.CTRL_DISCO: finish("server closed the connection")
            default: break
            }
        case Self.TYPE_ORIGINAL:
            if data.count >= 3 { onMessage?(readU16(data, 1), sliced(data, 3)) }
        case Self.TYPE_SPLIT:
            handleSplit(ch, data, insideReliable)
        case Self.TYPE_RELIABLE:
            if insideReliable || data.count < 4 { return }
            handleReliable(channel, ch, data)
        default: break
        }
    }

    private func handleReliable(_ channel: Int, _ ch: Channel, _ data: Data) {
        let seq = readU16(data, 1)
        let expected = ch.nextIncomingSeq
        if seqInWindow(seq, expected, Self.RECEIVE_WINDOW) {
            sendAck(channel, seq)
        } else {
            if seqHigher(expected, seq) { sendAck(channel, seq) }
            return
        }
        if seq != expected {
            if ch.incomingReliables[seq] == nil { ch.incomingReliables[seq] = sliced(data, 3) }
            return
        }
        handlePacket(channel, sliced(data, 3), true)
        ch.nextIncomingSeq = (ch.nextIncomingSeq + 1) & 0xFFFF
        while let inner = ch.incomingReliables[ch.nextIncomingSeq] {
            ch.incomingReliables.removeValue(forKey: ch.nextIncomingSeq)
            handlePacket(channel, inner, true)
            ch.nextIncomingSeq = (ch.nextIncomingSeq + 1) & 0xFFFF
        }
    }

    private func handleSplit(_ ch: Channel, _ data: Data, _ reliable: Bool) {
        guard data.count >= 7 else { return }
        let splitSeq = readU16(data, 1), count = readU16(data, 3), num = readU16(data, 5)
        guard count != 0, num < count else { return }
        // Mutate the entry in place: pulling it out into a local first left the
        // chunk dictionary shared with the stored copy, so every chunk's insert
        // copied all the chunks before it (a 2 MB media bunch is ~4000 chunks).
        if ch.incomingSplits[splitSeq] == nil {
            ch.incomingSplits[splitSeq] = (count: count, chunks: [:], reliable: reliable, time: time)
        }
        ch.incomingSplits[splitSeq]!.chunks[num] = sliced(data, 7)
        guard ch.incomingSplits[splitSeq]!.chunks.count >= count else { return }
        let s = ch.incomingSplits.removeValue(forKey: splitSeq)!
        var whole = Data()
        whole.reserveCapacity(s.chunks.values.reduce(0) { $0 + $1.count })
        for i in 0..<count { whole.append(s.chunks[i] ?? Data()) }
        if whole.count >= 2 { onMessage?(readU16(whole, 0), sliced(whole, 2)) }
    }

    private func sendRaw(_ pkt: Data) {
        conn?.send(content: pkt, completion: .contentProcessed { _ in })
        lastSent = time
    }

    /// One-shot UDP CONTROLTYPE_DISCO for OUR previous session, sent from the
    /// local port that session used: the server matches a datagram to a peer by
    /// sender address (connection.cpp), so this is the only way to say goodbye
    /// for a process that crashed. NWConnection won't reproduce the port, hence
    /// a plain BSD socket. Best-effort; host must be an IP literal.
    @discardableResult
    private static func sendDiscoForOwnStalePeer(host: String, serverPort: UInt16, localPort: UInt16, peerId: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var la = sockaddr_in(); la.sin_family = sa_family_t(AF_INET)
        la.sin_port = localPort.bigEndian; la.sin_addr.s_addr = 0   // INADDR_ANY
        let bound = withUnsafePointer(to: &la) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if bound != 0 { return false }
        var da = sockaddr_in(); da.sin_family = sa_family_t(AF_INET); da.sin_port = serverPort.bigEndian
        if inet_pton(AF_INET, host, &da.sin_addr) != 1 { return false }
        let pid = UInt32(PROTOCOL_ID)
        var pkt: [UInt8] = [UInt8(pid >> 24), UInt8((pid >> 16) & 0xFF), UInt8((pid >> 8) & 0xFF), UInt8(pid & 0xFF),
                            UInt8((peerId >> 8) & 0xFF), UInt8(peerId & 0xFF),
                            0, UInt8(TYPE_CONTROL), UInt8(CTRL_DISCO)]
        _ = withUnsafePointer(to: &da) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, &pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        print("[net] DISCO for our own stale peer=\(peerId) port=\(localPort) -> \(host):\(serverPort)"); fflush(stdout)
        return true
    }

    // MARK: byte helpers (all big-endian; `at` is an offset from the data start)
    private func baseHeader(channel: Int) -> Data {
        var d = Data(); appendU32(&d, Self.PROTOCOL_ID); appendU16(&d, peerId); d.append(UInt8(channel)); return d
    }
    private func appendU16(_ a: inout Data, _ v: Int) { a.append(UInt8((v >> 8) & 0xFF)); a.append(UInt8(v & 0xFF)) }
    private func appendU32(_ a: inout Data, _ v: Int) { for s in [24, 16, 8, 0] { a.append(UInt8((v >> s) & 0xFF)) } }
    private func readU16(_ a: Data, _ at: Int) -> Int { let i = a.startIndex + at; return (Int(a[i]) << 8) | Int(a[i + 1]) }
    private func readU32(_ a: Data, _ at: Int) -> Int {
        let i = a.startIndex + at
        return (Int(a[i]) << 24) | (Int(a[i + 1]) << 16) | (Int(a[i + 2]) << 8) | Int(a[i + 3])
    }
    private func sliced(_ a: Data, _ from: Int) -> Data { Data(a[(a.startIndex + from)...]) }

    private func seqHigher(_ totest: Int, _ base: Int) -> Bool {
        totest > base ? (totest - base) <= (Self.SEQNUM_MAX / 2) : (base - totest) > (Self.SEQNUM_MAX / 2)
    }
    private func seqInWindow(_ seq: Int, _ next: Int, _ window: Int) -> Bool {
        let windowEnd = (next + window) % (Self.SEQNUM_MAX + 1)
        return next < windowEnd ? (seq >= next && seq < windowEnd) : (seq < windowEnd || seq >= next)
    }
}
