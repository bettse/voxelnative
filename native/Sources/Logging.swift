import Foundation

// visionOS app stdout/stderr don't reach the devicectl console, so redirect
// them to a file in the app container that we pull with devicectl.
func redirectStdioToFile() {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let url = dir.appendingPathComponent("native.log")
    let path = url.path
    // Keep the previous run's log (native.log.prev) so a crash-then-relaunch
    // doesn't erase the crash session's log before we can pull it.
    let prev = dir.appendingPathComponent("native.log.prev")
    try? FileManager.default.removeItem(at: prev)
    try? FileManager.default.moveItem(at: url, to: prev)
    freopen(path, "w", stdout)
    freopen(path, "w", stderr)
    setvbuf(stdout, nil, _IONBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    print("=== native.log start \(Date()) ===")
    fflush(stdout)
}

/// Delete the in-headset screenshots (Documents/shot-*.png) when launched with
/// `-vrdev.clearShots 1`. The pull workflow runs this right after copying them
/// off the device so what remains on-device is only shots not yet reviewed. The
/// flag is a transient launch argument (NSArgumentDomain), not persisted, so a
/// normal launch never wipes pending shots.
/// Wipe all in-headset screenshots on every launch, so the app container only
/// ever holds shots from the current session: whatever is pulled off the device
/// is by definition new. Screenshots are manual (both grips), so there is
/// nothing auto-captured to lose; the tradeoff is that a batch must be pulled
/// before the next relaunch or it's gone (fine for the play -> pull -> relaunch
/// loop). -vrdev.keepShots opts out (e.g. to accumulate across sessions).
func clearScreenshotsIfRequested() {
    guard !UserDefaults.standard.bool(forKey: "vrdev.keepShots") else { return }
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let shots = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var n = 0
    for u in shots where u.lastPathComponent.hasPrefix("shot-") && u.pathExtension == "png" {
        try? FileManager.default.removeItem(at: u); n += 1
    }
    print("[shots] cleared \(n) screenshot(s) on launch"); fflush(stdout)
}
