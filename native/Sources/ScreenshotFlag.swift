import Foundation

/// Thread-safe one-shot flag: input thread requests a screenshot, the render
/// thread takes it on the next frame. Saved PNGs land in the app's Documents
/// dir (pull with `devicectl device copy from ... Documents/`).
final class ScreenshotFlag {
    private let lock = NSLock()
    private var pending = false
    func request() { lock.lock(); pending = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let p = pending; pending = false; return p }

    /// Photo mode video: the session sets it while recording; the renderer
    /// writes a frame every few frames while it's on and finishes the file
    /// when it goes off.
    private var _recording = false
    var recording: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _recording }
        set { lock.lock(); _recording = newValue; lock.unlock() }
    }

    /// Where and when the capture was taken (position, dimension, biome,
    /// server, build), set by the session as it requests a photo or starts a
    /// clip and written into the file's metadata by the renderer, so a bug
    /// report photo carries its own coordinates whether or not the HUD shows
    /// them. Not burned into the picture.
    private var _note = ""
    var note: String {
        get { lock.lock(); defer { lock.unlock() }; return _note }
        set { lock.lock(); _note = newValue; lock.unlock() }
    }
}
