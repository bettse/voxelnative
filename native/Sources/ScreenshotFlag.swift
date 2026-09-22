import Foundation

/// Thread-safe one-shot flag: input thread requests a screenshot, the render
/// thread takes it on the next frame. Saved PNGs land in the app's Documents
/// dir (pull with `devicectl device copy from ... Documents/`).
final class ScreenshotFlag {
    private let lock = NSLock()
    private var pending = false
    func request() { lock.lock(); pending = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let p = pending; pending = false; return p }
}
