import AVFoundation
import Foundation

extension AVCaptureDevice {
    func findVideoFormat(
        width: Int32,
        height: Int32,
        frameRate: Float64,
        isMultiCamSupported: Bool,
        appleLogSupported: Bool
    ) -> AVCaptureDevice.Format? {
        var matchingFormats = formats
            .filter { $0.isFrameRateSupported(frameRate) }
            .filter { width <= $0.formatDescription.dimensions.width }
            .filter { height <= $0.formatDescription.dimensions.height }
        if appleLogSupported {
            if #available(iOS 17.0, *) {
                matchingFormats = matchingFormats.filter { $0.supportedColorSpaces.contains(.appleLog) }
            }
        }
        if isMultiCamSupported {
            matchingFormats = matchingFormats.filter { $0.isMultiCamSupported }
        }
        return matchingFormats.first
    }
}
