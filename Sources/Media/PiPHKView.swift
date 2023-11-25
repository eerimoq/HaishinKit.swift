import AVFoundation
import Foundation
import UIKit

/// A view that displays a video content of a NetStream object which uses AVSampleBufferDisplayLayer api.
public class PiPHKView: UIView {
    /// The view’s background color.
    public static var defaultBackgroundColor: UIColor = .black

    /// Returns the class used to create the layer for instances of this class.
    override public class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    /// The view’s Core Animation layer used for rendering.
    override public var layer: AVSampleBufferDisplayLayer {
        super.layer as! AVSampleBufferDisplayLayer
    }

    /// A value that specifies how the video is displayed within a player layer’s bounds.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            if Thread.isMainThread {
                layer.videoGravity = videoGravity
            } else {
                DispatchQueue.main.sync {
                    layer.videoGravity = videoGravity
                }
            }
        }
    }

    /// A value that displays a video format.
    public var videoFormatDescription: CMVideoFormatDescription? {
        currentStream?.mixer.videoIO.formatDescription
    }

    public var isMirrored = false {
        didSet {
            let transform = CGAffineTransformMakeScale(isMirrored ? -1.0 : 1.0, 1.0)
            if Thread.isMainThread {
                layer.setAffineTransform(transform)
            } else {
                DispatchQueue.main.sync {
                    layer.setAffineTransform(transform)
                }
            }
        }
    }

    public var fps: Double?

    public var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            currentStream?.mixer.videoIO.videoOrientation = videoOrientation
        }
    }

    private weak var currentStream: NetStream? {
        didSet {
            oldValue?.mixer.videoIO.drawable = nil
        }
    }

    /// Initializes and returns a newly allocated view object with the specified frame rectangle.
    override public init(frame: CGRect) {
        super.init(frame: frame)
        awakeFromNib()
    }

    /// Returns an object initialized from data in a given unarchiver.
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    /// Prepares the receiver for service after it has been loaded from an Interface Builder archive, or
    /// nib file.
    override public func awakeFromNib() {
        super.awakeFromNib()
        backgroundColor = Self.defaultBackgroundColor
        layer.backgroundColor = Self.defaultBackgroundColor.cgColor
        layer.videoGravity = videoGravity
    }
}

extension PiPHKView: NetStreamDrawable {
    public func attachStream(_ stream: NetStream?) {
        guard let stream else {
            currentStream = nil
            return
        }
        stream.lockQueue.async {
            stream.mixer.videoIO.drawable = self
            self.currentStream = stream
            stream.mixer.startRunning()
        }
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer?) {
        if Thread.isMainThread {
            if let sampleBuffer {
                layer.enqueue(sampleBuffer)
            }
        } else {
            DispatchQueue.main.async {
                self.enqueue(sampleBuffer)
            }
        }
    }
}
