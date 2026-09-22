import Foundation

/// Cheap per-phase wall-clock accounting for the two hot loops (WorldSession
/// tick, Renderer frame). Enabled by -vrdev.perfStats or testing mode; off,
/// it costs one Bool check per phase. Every `period` seconds it prints one
/// line per loop with avg / max milliseconds per phase, so a device log
/// shows where the time actually goes instead of where a code read guesses.
final class PerfStats {
    static let enabled = UserDefaults.standard.bool(forKey: "vrdev.perfStats")
                      || UserDefaults.standard.bool(forKey: "vrdev.testingMode")
    /// Seconds since the process started, for stamping join milestones
    /// ("t=+3.2s") so a launch-to-world time can be read off any log.
    static let processStart = CFAbsoluteTimeGetCurrent()
    static func uptime() -> String { String(format: "t=+%.1fs", CFAbsoluteTimeGetCurrent() - processStart) }
    private let name: String
    private let period: Double
    private var phases: [(name: String, total: Double, max: Double)] = []
    private var index: [String: Int] = [:]
    private var samples = 0
    private var since = CFAbsoluteTimeGetCurrent()
    private var extra = ""

    init(_ name: String, period: Double = 5) { self.name = name; self.period = period }

    @inline(__always) func now() -> Double { PerfStats.enabled ? CFAbsoluteTimeGetCurrent() : 0 }

    /// Account `end - start` seconds to `phase`.
    func add(_ phase: String, _ start: Double, _ end: Double) {
        guard PerfStats.enabled else { return }
        let d = end - start
        if let i = index[phase] {
            phases[i].total += d; if d > phases[i].max { phases[i].max = d }
        } else {
            index[phase] = phases.count; phases.append((phase, d, d))
        }
    }

    /// Call once per loop iteration; `note` is appended to the line (counts).
    func endIteration(note: @autoclosure () -> String = "") {
        guard PerfStats.enabled else { return }
        samples += 1
        let t = CFAbsoluteTimeGetCurrent()
        guard t - since >= period, samples > 0 else { return }
        var line = "[perf] \(name) n=\(samples)"
        for p in phases {
            line += String(format: " %@=%.2f/%.1f", p.name, p.total * 1000 / Double(samples), p.max * 1000)
        }
        let n = note()
        if !n.isEmpty { line += " " + n }
        print(line); fflush(stdout)
        for i in phases.indices { phases[i].total = 0; phases[i].max = 0 }
        samples = 0; since = t
    }
}
