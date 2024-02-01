import AVFoundation
import Foundation

extension AVCaptureDevice {
    func findVideoFormat(
        width: Int32,
        height: Int32,
        frameRate: Float64,
        isMultiCamSupported: Bool,
        colorSpace: AVCaptureColorSpace
    ) -> AVCaptureDevice.Format? {
        var matchingFormats = formats
            .filter { $0.isFrameRateSupported(frameRate) }
            .filter { width <= $0.formatDescription.dimensions.width }
            .filter { height <= $0.formatDescription.dimensions.height }
            .filter { $0.supportedColorSpaces.contains(colorSpace) }
        if isMultiCamSupported {
            matchingFormats = matchingFormats.filter { $0.isMultiCamSupported }
        }
        return matchingFormats.first
    }
}
