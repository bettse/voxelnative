import Foundation

/// Downloads media (PNG textures, ...) over the game connection. Parses
/// TOCLIENT_ANNOUNCE_MEDIA, requests a chosen subset by name over
/// TOSERVER_REQUEST_MEDIA, and collects TOCLIENT_MEDIA into an in-memory store.
/// Remote HTTP media servers are ignored; we always pull from the game server.
/// Port of the conventional-transfer path of media_manager.gd.
public final class MediaManager {
    /// name -> file bytes (decompressed), for files we've received.
    public private(set) var store: [String: Data] = [:]
    /// All announced file names (whether requested or not).
    public private(set) var announced: Set<String> = []

    /// Server-announced sha1 (hex) per file name. The cache is keyed on this, so
    /// a file survives across launches and re-downloads only when its content
    /// (hence sha1) changes.
    private var sha1Hex: [String: String] = [:]
    /// On-disk media cache: <Caches>/media/<sha1hex>. Regenerable, so Caches.
    private let cacheDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var cacheHits = 0, downloaded = 0
    private static let cacheQueue = DispatchQueue(label: "voxel.media.cache", qos: .utility)
    private func cacheURL(_ name: String) -> URL? {
        guard let sha = sha1Hex[name], let dir = cacheDir else { return nil }
        return dir.appendingPathComponent(sha)
    }

    private var requested: Set<String> = []
    private var outstanding: Set<String> = []
    private var pending: [String] = []          // not-yet-requested, drained in batches
    /// A REQUEST_MEDIA is out and its reply's last bunch hasn't landed. The next
    /// batch waits for that, not for `outstanding` to drain: the reply usually
    /// ends with an empty bunch after the last file, and a request() from the
    /// session (entity tiles, a hotbar icon) arriving in that gap used to start
    /// the next batch early, so the straggler's "last bunch" was read against
    /// the NEW batch and wrongly wrote off all 128 of its files.
    private var awaitingReply = false
    private let batchSize = 128                  // bounded in-flight requests (VoxeLibre announces ~2000 files)
    private let send: (Int, Data) -> Void
    /// Called when every requested file has arrived.
    public var onComplete: (() -> Void)?
    /// MEDIA_PUSH bookkeeping: tokens the server wants acked (TOSERVER_HAVE_MEDIA)
    /// once the pushed file is on hand, by file name; fired via onPushedReady.
    private var pushTokens: [String: [Int]] = [:]
    public var onPushedReady: ((_ name: String, _ tokens: [Int]) -> Void)?
    public func pendingPushTokens(_ name: String) -> [Int] { pushTokens[name] ?? [] }

    /// A server-pushed file (TOCLIENT_MEDIA_PUSH, proto >= 40): remember the
    /// token to ack (TOSERVER_HAVE_MEDIA) once the file is on hand, and fetch
    /// it through the normal cache/request path if we don't have it yet.
    ///
    /// Same-sha1 pushes are the common case, not the exception: VoxeLibre's
    /// mcl_skins dynamic_add_media()s its base skin textures on every join, and
    /// those files are ALSO in the announce list. If the push lands while our
    /// initial download still has that name in flight, re-requesting it made the
    /// server refuse ("Client has requested X before, not sending it again",
    /// Server::sendRequestedMedia markMediaSent) and the name sat in
    /// `outstanding` forever: onComplete never fired, so a cold-cache join kept
    /// the colour-fallback atlas for the whole session. Mirror the real client
    /// (Client::handleCommand_MediaPush): an identical push merges into the
    /// ongoing request, and a file we already hold is acked straight away.
    public func push(name: String, sha1Hex hex: String, token: Int) {
        pushTokens[name, default: []].append(token)
        announced.insert(name)
        let unchanged = sha1Hex[name] == hex
        sha1Hex[name] = hex
        if unchanged {
            if store[name] != nil { pushedLanded(name); return }   // already have these bytes
            if requested.contains(name) { return }                   // arriving; ack when it lands
        } else {
            // New content under an old name. The server only allows that for the
            // same on-disk path (dynamicAddMedia), so it's rare; drop what we hold
            // so the sha1-keyed cache lookup can't short-circuit the fetch.
            store[name] = nil
            requested.remove(name)
        }
        request([name])
    }
    private func pushedLanded(_ name: String) {
        if let toks = pushTokens.removeValue(forKey: name) { onPushedReady?(name, toks) }
    }
    /// A file handed to us directly (legacy inline MEDIA_PUSH): store it and
    /// treat it as landed for any pending push tokens.
    public func accept(name: String, data: Data) {
        store[name] = data
        announced.insert(name)
        pushedLanded(name)
    }

    public init(send: @escaping (Int, Data) -> Void) { self.send = send }

    /// Lowercase hex of a digest. A nibble table, not String(format:): the
    /// announce carries ~3500 sha1s and formatting them byte by byte was
    /// 70k printf calls inside one packet handler on the tick thread.
    static func hex(_ d: Data) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(d.count * 2)
        for b in d { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0xF)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// A read-only copy for building the texture atlas off the tick queue.
    /// The atlas build reads `store` heavily, and poll (which downloads media)
    /// mutates `store` on the tick queue: a concurrent Swift-dict read/write can
    /// crash, so hand the builder its own COW copy (cheap: Data buffers are
    /// shared, only the dict spine is copied). The copy has a no-op `send` and is
    /// never used to request anything.
    public func snapshot() -> MediaManager {
        let m = MediaManager(send: { _, _ in })
        m.store = store
        m.announced = announced
        m.sha1Hex = sha1Hex
        return m
    }

    /// Reset the in-flight request bookkeeping for a reconnect. Keeps the
    /// downloaded `store` (and the on-disk cache) so cached files aren't re-fetched,
    /// but clears `requested`/`outstanding`/`pending` so a drop mid-download doesn't
    /// leave files stuck "requested but never arriving" — which would keep
    /// onComplete from ever firing and hang the reconnect half-initialized (F2).
    public func reset() {
        requested.removeAll(); outstanding.removeAll(); pending.removeAll()
        awaitingReply = false
    }

    public func has(_ name: String) -> Bool { store[name] != nil }
    public func bytes(_ name: String) -> Data? { store[name] }
    #if DEBUG
    /// Test seam: store raw bytes under a name (unit tests build synthetic PNGs).
    public func storeForTesting(_ name: String, _ data: Data) { store[name] = data }
    /// Test seam: the names of the request currently in flight.
    public var outstandingForTesting: Set<String> { outstanding }
    #endif

    /// All announced files ending in `.ogg` (the sound files). The server never
    /// splits these into node-tile requests, so we pull them explicitly.
    public func announcedSounds() -> Set<String> { announced.filter { $0.hasSuffix(".ogg") } }

    /// Resolve a sound base name (as sent by PLAY_SOUND) to a concrete downloaded
    /// `.ogg` in the store. The server registers each sound under a base name but
    /// may back it with several files ("<name>.ogg", "<name>.1.ogg", ...); it
    /// picks one at random per play, so we do too. Returns nil if none is present.
    public func resolveSound(_ name: String) -> String? {
        let exact = "\(name).ogg"
        var variants: [String] = []
        if store[exact] != nil { variants.append(exact) }
        let prefix = "\(name)."
        for key in store.keys where key != exact && key.hasPrefix(prefix) && key.hasSuffix(".ogg") {
            // Middle segment between "<name>." and ".ogg" must be all digits.
            let mid = key.dropFirst(prefix.count).dropLast(4)
            if !mid.isEmpty && mid.allSatisfy({ $0.isNumber }) { variants.append(key) }
        }
        return variants.randomElement()
    }

    /// TOCLIENT_ANNOUNCE_MEDIA (proto >= 48): zstd(string16 name array), then a
    /// 20-byte sha1 per name, then a string16 of remote URLs (ignored here).
    public func parseAnnounce(_ payload: Data) {
        let r = PacketReader(payload)
        guard let namesRaw = Zstd.decompress(r.bytes32(), maxSize: 16 * 1024 * 1024) else { return }
        // string16_array: u32 count, then all u16 lengths, then all string bytes.
        let nr = PacketReader(namesRaw)
        // A hostile/corrupt announce can declare a huge count; each name needs at
        // least its 2-byte length field in the buffer, so it can't exceed half
        // the decompressed size. Clamp so reserveCapacity can't be tricked into a
        // multi-GB allocation (parseMedia caps its file count the same way).
        let count = Int(nr.u32())
        guard count >= 0, count <= namesRaw.count / 2 else { return }
        var lengths: [Int] = []
        lengths.reserveCapacity(count)
        for _ in 0..<count { lengths.append(nr.u16()) }
        var names: [String] = []
        names.reserveCapacity(count)
        for len in lengths { names.append(String(decoding: nr.raw(len), as: UTF8.self)) }
        for n in names {                          // sha1 per file, in name order
            sha1Hex[n] = Self.hex(r.raw(20))
        }
        announced = Set(names)
    }

    /// Request the subset of announced files whose names are in `wanted`, in
    /// bounded batches, the way clientmedia.cpp paces its own REQUEST_MEDIA.
    public func request(_ wanted: Set<String>) {
        var toGet = wanted.intersection(announced).subtracting(requested)
        // Serve anything already in the on-disk cache (keyed by the announced
        // sha1) without touching the network; only download the misses.
        var hits: [String] = []
        let t0 = DispatchTime.now().uptimeNanoseconds
        for name in toGet where store[name] == nil {
            if let url = cacheURL(name), let data = try? Data(contentsOf: url) {
                store[name] = data; requested.insert(name); hits.append(name)
                pushedLanded(name)
            }
        }
        if !hits.isEmpty {
            toGet.subtract(hits); cacheHits += hits.count
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            print("[media] cache hit \(hits.count) (\(cacheHits) total) in \(Int(ms)) ms"); fflush(stdout)
        }
        guard !toGet.isEmpty else { if !awaitingReply && pending.isEmpty { onComplete?() }; return }
        // Mark as requested NOW, not when the batch goes out: a name parked in
        // `pending` used to be re-queued by every request() that named it again
        // (the HUD asks for its boss-bar/potion icons each tick), so it went out
        // in two batches and the server refused the second ("requested before").
        requested.formUnion(toGet)
        pending.append(contentsOf: toGet)
        requestNextBatch()
    }

    private func requestNextBatch() {
        guard !awaitingReply, !pending.isEmpty else { return }
        let batch = Array(pending.prefix(batchSize))
        pending.removeFirst(batch.count)
        outstanding.formUnion(batch)
        awaitingReply = true
        let w = PacketWriter().u16(batch.count)
        for n in batch { w.string16(n) }
        send(Op.toserverRequestMedia, w.data)
    }

    /// TOCLIENT_MEDIA: u16 num_bunches, u16 bunch, u32 num_files, then per file
    /// string16 name + bytes32 data (zstd-compressed at proto >= 48).
    public func parseMedia(_ payload: Data) {
        let r = PacketReader(payload)
        let numBunches = r.u16()
        let bunch = r.u16()
        let numFiles = r.u32()
        if numFiles < 0 || numFiles > 100_000 { print("[media] bogus numFiles=\(numFiles)"); fflush(stdout); return }
        for _ in 0..<numFiles {
            let name = r.string16()
            let comp = r.bytes32()
            if name.isEmpty && comp.isEmpty { break }   // ran off the end of a short/corrupt blob
            let data = Zstd.decompress(comp, maxSize: 8 * 1024 * 1024) ?? comp
            store[name] = data
            downloaded += 1
            pushedLanded(name)
            if let url = cacheURL(name) {
                // Populate the on-disk cache for next launch off the tick thread:
                // the stat + atomic write per file (temp + rename) was ~90 ms of
                // poll stall per bunch on a cold join. Write failures are fine,
                // the file just gets downloaded again next time.
                Self.cacheQueue.async {
                    if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic) }
                }
            }
            outstanding.remove(name)
        }
        // One reply per request, bunches 0..<num_bunches in order (reliable
        // channel), and the reply often ends with an EMPTY bunch: the server
        // opens a fresh bunch once the byte budget is hit, even after the last
        // file. So only the last bunch ends the batch. Moving on as soon as
        // `outstanding` drained would let that trailing empty bunch land on the
        // NEXT batch's bookkeeping. And the last bunch is everything the server
        // will ever send for this request: a name it skipped (unknown, or one it
        // thinks it already sent us) must not pin `outstanding` and stall the
        // whole download behind it.
        guard bunch + 1 >= numBunches else { return }
        awaitingReply = false
        if !outstanding.isEmpty {
            print("[media] server skipped \(outstanding.count) requested file(s): \(outstanding.sorted().prefix(8).joined(separator: ", "))"); fflush(stdout)
            outstanding.removeAll()
        }
        if pending.isEmpty { onComplete?() } else { requestNextBatch() }
    }
}
