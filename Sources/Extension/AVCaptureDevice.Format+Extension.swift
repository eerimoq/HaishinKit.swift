import AVFoundation
import Foundation

extension AVCaptureDevice.Format {
    func isFrameRateSupported(_ frameRate: Float64) -> Bool {
        for fpsRange in videoSupportedFrameRateRanges {
            if fpsRange.contains(frameRate: frameRate) {
                return true
            }
        }
        return false
    }
}
