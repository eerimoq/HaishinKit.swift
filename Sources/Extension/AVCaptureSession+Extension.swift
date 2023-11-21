import AVFoundation
import Foundation

// swiftlint:disable unused_setter_value
extension AVCaptureSession {
    @available(iOS, obsoleted: 16.0)
    var isMultitaskingCameraAccessSupported: Bool {
        false
    }

    @available(iOS, obsoleted: 16.0)
    var isMultitaskingCameraAccessEnabled: Bool {
        get {
            false
        }
        set {
            logger.warn("isMultitaskingCameraAccessEnabled is unavailabled in under iOS 16.")
        }
    }
}

// swiftlint:enable unused_setter_value
