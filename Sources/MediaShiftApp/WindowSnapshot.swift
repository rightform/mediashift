#if DEBUG
import AppKit

/// Saves a picture of one of the app's own windows. Debug builds only, for visual checks.
enum WindowSnapshot {
    private typealias CaptureFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func save(_ window: NSWindow, to url: URL) {
        // The call is hidden from newer SDKs but still works for a process's own windows.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        guard let image = capture(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming)?.takeRetainedValue() else { return }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? data?.write(to: url)
    }
}
#endif
