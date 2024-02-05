import AVFoundation
import CoreImage

open class VideoEffect: NSObject {
    public var ciContext: CIContext?

    open func execute(_ image: CIImage, info _: CMSampleBuffer?) -> CIImage {
        image
    }
}
