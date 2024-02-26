import AVFoundation
import CoreImage

open class VideoEffect: NSObject {
    // public var ciContext: CIContext?
    public var name: String = ""

    open func execute(_ image: CIImage, info _: CMSampleBuffer?) -> CIImage {
        image
    }
}
