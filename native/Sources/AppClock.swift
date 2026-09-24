import Foundation

/// Seconds since launch on a monotonic clock, for animation and timers. Built
/// on ContinuousClock rather than systemUptime / CACurrentMediaTime: those read
/// the system boot time, which Apple makes an app justify in its privacy
/// manifest, and nothing here needs time since boot, only time that doesn't
/// jump backward.
enum AppClock {
    private static let start = ContinuousClock.now

    static var seconds: Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) * 1e-18
    }
}
