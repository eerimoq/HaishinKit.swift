import Accelerate
import CoreMedia
import Foundation

/// The MultiCamCaptureSetting represents the pip capture settings for the video capture.
public struct MultiCamCaptureSettings: Codable {
    /// The type of image display mode.
    public enum Mode: String, Codable {
        /// The picture in picture mode means video stream playing within an inset window, freeing the rest of the screen for other tasks.
        case pip
        /// The split view means video stream playing within two individual windows.
        case splitView
    }

    /// The default setting for the stream.
    public static let `default` = MultiCamCaptureSettings(
        mode: .pip,
        cornerRadius: 0.0,
        regionOfInterest: .init(
            origin: CGPoint(x: 0, y: 0),
            size: .init(width: 640, height: 360)
        ),
        direction: .east
    )

    /// The image display mode.
    public let mode: Mode
    /// The cornerRadius of the picture in picture image.
    public let cornerRadius: CGFloat
    /// The region of the picture in picture image.
    public let regionOfInterest: CGRect
    /// The direction of the splitView position.
    public let direction: ImageTransform

    /// Create a new MultiCamCaptureSetting.
    public init(mode: Mode, cornerRadius: CGFloat, regionOfInterest: CGRect, direction: ImageTransform) {
        self.mode = mode
        self.cornerRadius = cornerRadius
        self.regionOfInterest = regionOfInterest
        self.direction = direction
    }
}
