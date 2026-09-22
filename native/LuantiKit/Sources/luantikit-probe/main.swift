import Foundation
import LuantiKit

// Headless smoke test for the LuantiKit package (a command-line tool, not part
// of the shipped visionOS app: it's a separate SPM executable target). It logs
// in to the developer's OWN VoxeLibre dev server (tools/server.sh on this
// machine, default 127.0.0.1:30000) with the same SRP-6a join sequence the
// official Luanti client performs, waits for CLIENT_READY, and prints how many
// map blocks streamed in and how many solid nodes they hold. That's the
// cheapest way to check the protocol layer end to end without a headset or
// the simulator. It is not a general-purpose client and is only ever run
// against that local server. Usage: luantikit-probe [host] [port] [name] [password]
let args = CommandLine.arguments
let host = args.count > 1 ? args[1] : "127.0.0.1"
let port = UInt16(args.count > 2 ? args[2] : "30000") ?? 30000
let name = args.count > 3 ? args[3] : "vrdev-probe"
let password = args.count > 4 ? args[4] : ""


let client = Client(name: name, password: password)
var done = false
var blockCount = 0
var solidNodes = 0
var authed = false

client.onAuthenticated = { seed in
    authed = true
    print("AUTHENTICATED  map_seed=\(seed)  (name=\(name))")
}
client.onBlock = { bpos in
    blockCount += 1
    if let b = client.world.blocks[bpos] {
        for c in b.param0 where c != WorldMap.CONTENT_AIR && c != WorldMap.CONTENT_IGNORE { solidNodes += 1 }
    }
    if blockCount <= 5 { print("  block \(bpos)  solid-so-far=\(solidNodes)") }
}
client.onAccessDenied = { reason, _ in print("ACCESS DENIED: \(reason)"); done = true }
client.onDisconnected = { reason in print("disconnected: \(reason)"); done = true }

print("connecting to \(host):\(port) as \(name)...")
client.connect(host: host, port: port)

let start = Date(); var last = Date()
var mediaDone = false
client.onMediaReady = { mediaDone = true }
while !done && !mediaDone && Date().timeIntervalSince(start) < 40 {
    let now = Date(); client.poll(now.timeIntervalSince(last)); last = now
    Thread.sleep(forTimeInterval: 0.016)
}

print("---")
print("authed=\(authed)  blocks=\(blockCount)  solidNodes=\(solidNodes)")
let probeAtlas = TextureAtlas(); probeAtlas.build(nodes: client.nodes, media: client.media)
let m = WorldMesher.build(client.world, atlas: probeAtlas, nodes: client.nodes, origin: .zero, scale: 1.0)
let mesh = m.opaque
print("liquid tris=\(m.liquid.indices.count/3)")
print("opaque split: solid tris=\(mesh.solid.count/3)  cutout tris=\(mesh.cutout.count/3)")
print("entities=\(client.objects.snapshot().count)")
print("mesh: vertices=\(mesh.vertices.count / 8)  triangles=\((mesh.solid.count + mesh.cutout.count) / 3)  nodeTypes=\(client.nodes.count)")
var withTex = 0
for tiles in client.nodes.faceTiles.values where tiles.contains(where: { !$0.isEmpty }) { withTex += 1 }
print("media: announced=\(client.media.announced.count)  downloaded=\(client.media.store.count)  nodesWithTiles=\(withTex)")
if let sample = client.media.store.first { print("  sample file: \(sample.key) (\(sample.value.count) bytes)") }
let atlas = TextureAtlas()
atlas.build(nodes: client.nodes, media: client.media)
print("atlas: layers=\(atlas.layerCount)")
// sanity: how many decodable PNGs among downloaded
var decoded = 0
for (_, d) in client.media.store where TextureAtlas.decodePNG(d, size: 16) != nil { decoded += 1 }
print("atlas: decodablePNGs=\(decoded)/\(client.media.store.count)")
// nodebox parse sanity: how many nodes parsed a nodebox, with a few examples.
var nodeboxCount = 0
var examples: [String] = []
for (id, name) in client.nodes.names {
    if client.nodes.kind(id) == .nodebox, let b = client.nodes.boxes(id) {
        nodeboxCount += 1
        if examples.count < 8 { examples.append("\(name)[\(b.count) box]") }
    }
}
print("nodebox: nodes=\(nodeboxCount)  e.g. \(examples.joined(separator: ", "))")
if !done { print("TIMEOUT (no ACCESS_DENIED, may just be slow streaming)") }
client.disconnect()
Thread.sleep(forTimeInterval: 0.5)
exit(blockCount > 0 ? 0 : 1)
