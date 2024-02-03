import AVFoundation
import Foundation

extension AVCaptureDevice {
    func findVideoFormat(
        width: Int32,
        height: Int32,
        frameRate: Float64,
        colorSpace: AVCaptureColorSpace
    ) -> AVCaptureDevice.Format? {
        return formats
            .filter { $0.isFrameRateSupported(frameRate) }
            .filter { width <= $0.formatDescription.dimensions.width }
            .filter { height <= $0.formatDescription.dimensions.height }
            .filter { $0.supportedColorSpaces.contains(colorSpace) }.first
    }
}
