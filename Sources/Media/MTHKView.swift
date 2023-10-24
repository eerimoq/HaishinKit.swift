import AVFoundation
import MetalKit

private let imageQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.MTHKView")

/**
 * A view that displays a video content of a NetStream object which uses Metal api.
 */
public class MTHKView: MTKView {
    public var isMirrored = false
    /// Specifies how the video is displayed within a player layer’s bounds.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect
    public var fps: Double? = nil
    private var nextTime = -1.0
    public var videoFormatDescription: CMVideoFormatDescription? {
        currentStream?.mixer.videoIO.formatDescription
    }

    #if os(iOS) || os(macOS)
    /// Specifies the orientation of AVCaptureVideoOrientation.
    public var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            currentStream?.mixer.videoIO.videoOrientation = videoOrientation
        }
    }
    #endif
    
    private var currentDisplayImage: CIImage?
    private let colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()

    private lazy var commandQueue: (any MTLCommandQueue)? = {
        return device?.makeCommandQueue()
    }()

    private weak var currentStream: NetStream? {
        didSet {
            oldValue?.mixer.videoIO.drawable = nil
            if let currentStream = currentStream {
                currentStream.mixer.videoIO.context = CIContext(mtlDevice: device!)
                currentStream.lockQueue.async {
                    currentStream.mixer.videoIO.drawable = self
                    currentStream.mixer.startRunning()
                }
            }
        }
    }

    /// Initializes and returns a newly allocated view object with the specified frame rectangle.
    public init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        awakeFromNib()
    }

    /// Returns an object initialized from data in a given unarchiver.
    public required init(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.device = MTLCreateSystemDefaultDevice()
    }

    /// Prepares the receiver for service after it has been loaded from an Interface Builder archive, or nib file.
    override open func awakeFromNib() {
        super.awakeFromNib()
        delegate = self
        framebufferOnly = false
        enableSetNeedsDisplay = true
    }
}

extension MTHKView: NetStreamDrawable {
    // MARK: NetStreamDrawable
    public func attachStream(_ stream: NetStream?) {
        if Thread.isMainThread {
            currentStream = stream
        } else {
            DispatchQueue.main.async {
                self.currentStream = stream
            }
        }
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer?) {
        imageQueue.async {
            guard let sampleBuffer else {
                return
            }
            guard let imageBuffer = sampleBuffer.imageBuffer else {
                return
            }
            // Just approximate FPS for now.
            if let fps = self.fps {
                if sampleBuffer.presentationTimeStamp.seconds < self.nextTime {
                    return
                }
                self.nextTime = sampleBuffer.presentationTimeStamp.seconds + 1.0 / fps
            }
            let displayImage = CIImage(cvPixelBuffer: imageBuffer)
            self.enqueueDisplayImage(displayImage, sampleBuffer.presentationTimeStamp)
        }
    }

    public func enqueueDisplayImage(_ displayImage: CIImage, _ presentationTimeStamp: CMTime) {
        if Thread.isMainThread {
            currentDisplayImage = displayImage
            #if os(macOS)
            self.needsDisplay = true
            #else
            self.setNeedsDisplay()
            #endif
        } else {
            DispatchQueue.main.async {
                self.enqueueDisplayImage(displayImage, presentationTimeStamp)
            }
        }
    }
}

extension MTHKView: MTKViewDelegate {
    // MARK: MTKViewDelegate
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    public func draw(in view: MTKView) {
        guard
            let currentDrawable = currentDrawable,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let context = currentStream?.mixer.videoIO.context else {
            return
        }
        if
            let currentRenderPassDescriptor = currentRenderPassDescriptor,
            let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor) {
            renderCommandEncoder.endEncoding()
        }
        guard var displayImage = currentDisplayImage else {
            commandBuffer.present(currentDrawable)
            commandBuffer.commit()
            return
        }
        var scaleX: CGFloat = 0
        var scaleY: CGFloat = 0
        switch videoGravity {
        case .resize:
            scaleX = drawableSize.width / displayImage.extent.width
            scaleY = drawableSize.height / displayImage.extent.height
        case .resizeAspect:
            let scale: CGFloat = min(drawableSize.width / displayImage.extent.width, drawableSize.height / displayImage.extent.height)
            scaleX = scale
            scaleY = scale
        case .resizeAspectFill:
            let scale: CGFloat = max(drawableSize.width / displayImage.extent.width, drawableSize.height / displayImage.extent.height)
            scaleX = scale
            scaleY = scale
        default:
            break
        }

        if isMirrored {
            displayImage = displayImage.oriented(.upMirrored)
        }

        displayImage = displayImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let bounds = CGRect(origin: .zero, size: drawableSize)
        context.render(displayImage, to: currentDrawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
}
