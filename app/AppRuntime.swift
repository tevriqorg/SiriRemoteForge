import Foundation

/// Owns the long-lived physical-input subsystem graph. AppKit composition remains in AppDelegate,
/// while device/HID lifecycle has one explicit owner and one passive-input shutdown boundary.
/// All calls are made from the application main thread; worker internals keep their own queues.
final class AppRuntime {
    var remoteDetector: RemoteDetector?
    var remoteInputHandler: RemoteInputHandler?
    var mediaKeyInterceptor: MediaKeyInterceptor?
    var touchHandler: TouchHandler?

    func stopPassiveInput() {
        dispatchPrecondition(condition: .onQueue(.main))
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
    }
}
