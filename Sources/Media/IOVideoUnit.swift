import AVFoundation
import CoreImage

final class IOVideoUnit: NSObject, IOUnit {
    enum Error: Swift.Error {
        case multiCamNotSupported
    }

    static let defaultAttributes: [NSString: NSObject] = [
        kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
    ]

    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoIOComponent.lock")

    var context: CIContext = .init() {
        didSet {
            for effect in effects {
                effect.ciContext = context
            }
        }
    }

    weak var drawable: (any NetStreamDrawable)? {
        didSet {
            // print("drawable", drawable)
            // drawable?.videoOrientation = videoOrientation
        }
    }

    var formatDescription: CMVideoFormatDescription? {
        didSet {
            codec.formatDescription = formatDescription
        }
    }

    lazy var codec: VideoCodec = {
        var codec = VideoCodec()
        codec.lockQueue = lockQueue
        return codec
    }()

    weak var mixer: IOMixer?

    var muted = false

    private(set) var effects: [VideoEffect] = []

    private var extent = CGRect.zero {
        didSet {
            guard extent != oldValue else {
                return
            }
        }
    }

    private var attributes: [NSString: NSObject] {
        var attributes: [NSString: NSObject] = Self.defaultAttributes
        attributes[kCVPixelBufferWidthKey] = NSNumber(value: Int(extent.width))
        attributes[kCVPixelBufferHeightKey] = NSNumber(value: Int(extent.height))
        return attributes
    }

    var frameRate = IOMixer.defaultFrameRate {
        didSet {
            capture.setFrameRate(frameRate)
            multiCamCapture.setFrameRate(frameRate)
        }
    }

    var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            guard videoOrientation != oldValue else {
                return
            }
            mixer?.session.beginConfiguration()
            defer {
                mixer?.session.commitConfiguration()
                // https://github.com/shogo4405/HaishinKit.swift/issues/190
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.torch {
                        self.setTorchMode(.on)
                    }
                }
            }
            drawable?.videoOrientation = videoOrientation
            capture.videoOrientation = videoOrientation
            multiCamCapture.videoOrientation = videoOrientation
        }
    }

    var torch = false {
        didSet {
            guard torch != oldValue else {
                return
            }
            setTorchMode(torch ? .on : .off)
        }
    }

    private(set) var capture: IOVideoCaptureUnit = .init()
    private(set) var multiCamCapture: IOVideoCaptureUnit = .init()
    var multiCamCaptureSettings: MultiCamCaptureSettings = .default
    private var multiCamSampleBuffer: CMSampleBuffer?

    func attachCamera(_ device: AVCaptureDevice?) throws {
        guard let mixer, capture.device != device else {
            return
        }
        guard let device else {
            logger.info("Detaching camera")
            mixer.mediaSync = .passthrough
            mixer.session.beginConfiguration()
            defer {
                mixer.session.commitConfiguration()
            }
            capture.detachSession(mixer.session)
            try capture.attachDevice(nil, videoUnit: self)
            return
        }
        logger.info("Attaching camera")
        mixer.mediaSync = .video
        mixer.session.beginConfiguration()
        defer {
            mixer.session.commitConfiguration()
            if torch {
                setTorchMode(.on)
            }
        }
        if multiCamCapture.device == device {
            try multiCamCapture.attachDevice(nil, videoUnit: self)
        }
        try capture.attachDevice(device, videoUnit: self)
    }

    func attachMultiCamera(_ device: AVCaptureDevice?) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw Error.multiCamNotSupported
        }
        guard let mixer, multiCamCapture.device != device else {
            return
        }
        guard let device else {
            logger.info("Detaching multi camera")
            mixer.session.beginConfiguration()
            defer {
                mixer.session.commitConfiguration()
            }
            multiCamCapture.detachSession(mixer.session)
            try multiCamCapture.attachDevice(nil, videoUnit: self)
            mixer.isMultiCamSessionEnabled = false
            return
        }
        logger.info("Attaching multi camera")
        mixer.isMultiCamSessionEnabled = true
        mixer.session.beginConfiguration()
        defer {
            mixer.session.commitConfiguration()
        }
        if capture.device == device {
            try multiCamCapture.attachDevice(nil, videoUnit: self)
        }
        try multiCamCapture.attachDevice(device, videoUnit: self)
    }

    func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        capture.setTorchMode(torchMode)
        multiCamCapture.setTorchMode(torchMode)
    }

    @inline(__always)
    func effect(_ buffer: CVImageBuffer, info: CMSampleBuffer?) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer)
        for effect in effects {
            image = effect.execute(image, info: info)
        }
        return image
    }

    func registerEffect(_ effect: VideoEffect) -> Bool {
        effect.ciContext = context
        if effects.contains(effect) {
            return false
        } else {
            effects.append(effect)
            return true
        }
    }

    func unregisterEffect(_ effect: VideoEffect) -> Bool {
        effect.ciContext = nil
        if let index = effects.firstIndex(of: effect) {
            effects.remove(at: index)
            return true
        } else {
            return false
        }
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        logger.info("Append sample buffer")
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        setSampleBufferAttachments(sampleBuffer)
        imageBuffer.lockBaseAddress()
        defer {
            imageBuffer.unlockBaseAddress()
        }
        if let multiCamPixelBuffer = multiCamSampleBuffer?.imageBuffer {
            multiCamPixelBuffer.lockBaseAddress()
            switch multiCamCaptureSettings.mode {
            case .pip:
                imageBuffer.over(
                    multiCamPixelBuffer,
                    regionOfInterest: multiCamCaptureSettings.regionOfInterest,
                    radius: multiCamCaptureSettings.cornerRadius
                )
            case .splitView:
                imageBuffer.split(multiCamPixelBuffer, direction: multiCamCaptureSettings.direction)
            }
            multiCamPixelBuffer.unlockBaseAddress()
        }
        if !effects.isEmpty {
            let image = effect(imageBuffer, info: sampleBuffer)
            extent = image.extent
            if imageBuffer.width != Int(extent.width) || imageBuffer.height != Int(extent.height) {
                logger.info("effect image wrong size")
                return
            }
            context.render(image, to: imageBuffer)
        }
        drawable?.enqueue(sampleBuffer)
        codec.appendImageBuffer(
            imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration
        )
    }
}

extension IOVideoUnit: IOUnitEncoding {
    func startEncoding(_ delegate: any AVCodecDelegate) {
        codec.delegate = delegate
        codec.startRunning()
    }

    func stopEncoding() {
        codec.stopRunning()
        codec.delegate = nil
    }
}

extension IOVideoUnit: IOUnitDecoding {
    func startDecoding() {
        codec.delegate = self
        codec.startRunning()
    }

    func stopDecoding() {
        codec.stopRunning()
        drawable?.enqueue(nil)
    }
}

private func setSampleBufferAttachments(_ sampleBuffer: CMSampleBuffer) {
    let attachments: CFArray! = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                   to: CFMutableDictionary.self)
    let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
    let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
    CFDictionarySetValue(dictionary, key, value)
}

extension IOVideoUnit: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ captureOutput: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        if capture.output == captureOutput {
            guard mixer?.useSampleBuffer(sampleBuffer: sampleBuffer, mediaType: AVMediaType.video) == true
            else {
                return
            }
            appendSampleBuffer(sampleBuffer)
        } else if multiCamCapture.output == captureOutput {
            multiCamSampleBuffer = sampleBuffer
        }
    }
}

extension IOVideoUnit: VideoCodecDelegate {
    // MARK: VideoCodecDelegate

    func videoCodec(_: VideoCodec, didOutput _: CMFormatDescription?) {}

    func videoCodec(_: VideoCodec, didOutput sampleBuffer: CMSampleBuffer) {
        mixer?.mediaLink.enqueueVideo(sampleBuffer)
    }

    func videoCodec(_: VideoCodec, errorOccurred error: VideoCodec.Error) {
        logger.trace(error)
    }

    func videoCodecWillDropFame(_: VideoCodec) -> Bool {
        return false
    }
}
