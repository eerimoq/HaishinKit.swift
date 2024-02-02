import AVFoundation
import CoreImage
import UIKit

public var ioVideoUnitIgnoreFramesAfterAttachSeconds = 0.3

class ReplaceVideo {
    var sampleBuffers: [CMSampleBuffer] = []
    var firstPresentationTimeStamp: Double = .nan
    var currentSampleBuffer: CMSampleBuffer?
    var latency: Double

    init(latency: Double) {
        self.latency = latency
    }

    func updateSampleBuffer(_ realPresentationTimeStamp: Double) {
        var sampleBuffer = currentSampleBuffer
        while !sampleBuffers.isEmpty {
            let replaceSampleBuffer = sampleBuffers.first!
            // Get first frame quickly
            if currentSampleBuffer == nil {
                sampleBuffer = replaceSampleBuffer
            }
            // Just for sanity. Should depend on FPS and latency.
            if sampleBuffers.count > 200 {
                // logger.info("Over 200 frames buffered. Dropping oldest frame.")
                sampleBuffer = replaceSampleBuffer
                sampleBuffers.remove(at: 0)
                continue
            }
            let presentationTimeStamp = replaceSampleBuffer.presentationTimeStamp.seconds
            if firstPresentationTimeStamp.isNaN {
                firstPresentationTimeStamp = realPresentationTimeStamp - presentationTimeStamp
            }
            if firstPresentationTimeStamp + presentationTimeStamp + latency > realPresentationTimeStamp {
                break
            }
            sampleBuffer = replaceSampleBuffer
            sampleBuffers.remove(at: 0)
        }
        currentSampleBuffer = sampleBuffer
    }

    func getSampleBuffer(_ realSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        if let currentSampleBuffer {
            return makeSampleBuffer(
                realSampleBuffer: realSampleBuffer,
                replaceSampleBuffer: currentSampleBuffer
            )
        } else {
            return nil
        }
    }

    private func makeSampleBuffer(realSampleBuffer: CMSampleBuffer,
                                  replaceSampleBuffer: CMSampleBuffer) -> CMSampleBuffer?
    {
        var timing = CMSampleTimingInfo(
            duration: realSampleBuffer.duration,
            presentationTimeStamp: realSampleBuffer.presentationTimeStamp,
            decodeTimeStamp: realSampleBuffer.decodeTimeStamp
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: replaceSampleBuffer.imageBuffer!,
            formatDescription: replaceSampleBuffer.formatDescription!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        sampleBuffer?.isNotSync = replaceSampleBuffer.isNotSync
        return sampleBuffer
    }
}

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
            capture.setFrameRate(frameRate: frameRate, colorSpace: colorSpace)
            multiCamCapture.setFrameRate(frameRate: frameRate, colorSpace: colorSpace)
        }
    }

    var colorSpace = AVCaptureColorSpace.sRGB {
        didSet {
            capture.setFrameRate(frameRate: frameRate, colorSpace: colorSpace)
        }
    }

    var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            guard videoOrientation != oldValue else {
                return
            }
            mixer?.videoSession.beginConfiguration()
            defer {
                mixer?.videoSession.commitConfiguration()
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
    private var selectedReplaceVideoCameraId: UUID?
    private var replaceVideos: [UUID: ReplaceVideo] = [:]
    private var blackImageBuffer: CVPixelBuffer?
    private var blackFormatDescription: CMVideoFormatDescription?
    private var blackPixelBufferPool: CVPixelBufferPool?
    private var latestSampleBuffer: CMSampleBuffer?
    private var latestSampleBufferDate: Date?
    private var gapFillerTimer: DispatchSourceTimer?
    private var firstFrameDate: Date?
    private var isFirstAfterAttach = false

    override init() {
        gapFillerTimer = DispatchSource.makeTimerSource(queue: lockQueue)
        super.init()
        gapFillerTimer!.schedule(deadline: .now() + 0.1, repeating: 0.1)
        gapFillerTimer!.setEventHandler { [weak self] in
            self?.handleGapFillerTimer()
        }
        gapFillerTimer!.activate()
    }

    deinit {
        gapFillerTimer?.cancel()
        gapFillerTimer = nil
    }

    private func handleGapFillerTimer() {
        guard let latestSampleBufferDate else {
            return
        }
        let delta = Date().timeIntervalSince(latestSampleBufferDate)
        guard delta > 0.1 else {
            return
        }
        guard let latestSampleBuffer else {
            return
        }
        let timeDelta = CMTime(seconds: delta, preferredTimescale: 1000)
        var timing = CMSampleTimingInfo(
            duration: latestSampleBuffer.duration,
            presentationTimeStamp: latestSampleBuffer.presentationTimeStamp + timeDelta,
            decodeTimeStamp: latestSampleBuffer.decodeTimeStamp + timeDelta
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: latestSampleBuffer.imageBuffer!,
            formatDescription: latestSampleBuffer.formatDescription!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return
        }
        guard mixer?.useSampleBuffer(sampleBuffer: sampleBuffer!, mediaType: AVMediaType.video) == true
        else {
            return
        }
        appendSampleBuffer(sampleBuffer!, isFirstAfterAttach: false, skipEffects: true)
    }

    func attachCamera(_ device: AVCaptureDevice?, _ replaceVideo: UUID?) throws {
        let isOtherReplaceVideo = lockQueue.sync {
            let oldReplaceVideo = self.selectedReplaceVideoCameraId
            self.selectedReplaceVideoCameraId = replaceVideo
            return replaceVideo != oldReplaceVideo
        }
        guard let mixer else {
            return
        }
        if capture.device == device {
            if isOtherReplaceVideo {
                lockQueue.sync {
                    firstFrameDate = nil
                    isFirstAfterAttach = true
                }
            }
            return
        }
        guard let device else {
            mixer.mediaSync = .passthrough
            mixer.videoSession.beginConfiguration()
            defer {
                mixer.videoSession.commitConfiguration()
            }
            capture.detachSession(mixer.videoSession)
            try capture.attachDevice(nil, videoUnit: self)
            return
        }
        mixer.mediaSync = .video
        mixer.videoSession.beginConfiguration()
        defer {
            mixer.videoSession.commitConfiguration()
            if torch {
                setTorchMode(.on)
            }
        }
        if multiCamCapture.device == device {
            try multiCamCapture.attachDevice(nil, videoUnit: self)
        }
        try capture.attachDevice(device, videoUnit: self)
        // Not perfect. Should be set before registering the capture callback
        lockQueue.sync {
            firstFrameDate = nil
            isFirstAfterAttach = true
        }
    }

    func attachMultiCamera(_ device: AVCaptureDevice?) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw Error.multiCamNotSupported
        }
        guard let mixer, multiCamCapture.device != device else {
            return
        }
        guard let device else {
            mixer.videoSession.beginConfiguration()
            defer {
                mixer.videoSession.commitConfiguration()
            }
            multiCamCapture.detachSession(mixer.videoSession)
            try multiCamCapture.attachDevice(nil, videoUnit: self)
            mixer.isMultiCamSessionEnabled = false
            return
        }
        logger.info("Attaching multi camera")
        mixer.isMultiCamSessionEnabled = true
        mixer.videoSession.beginConfiguration()
        defer {
            mixer.videoSession.commitConfiguration()
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

    func addReplaceVideoSampleBuffer(id: UUID, _ sampleBuffer: CMSampleBuffer) {
        guard let replaceVideo = replaceVideos[id] else {
            return
        }
        replaceVideo.sampleBuffers.append(sampleBuffer)
        replaceVideo.sampleBuffers.sort { sampleBuffer1, sampleBuffer2 in
            sampleBuffer1.presentationTimeStamp < sampleBuffer2.presentationTimeStamp
        }
    }

    func addReplaceVideo(cameraId: UUID, latency: Double) {
        let replaceVideo = ReplaceVideo(latency: latency)
        replaceVideos[cameraId] = replaceVideo
    }

    func removeReplaceVideo(cameraId: UUID) {
        replaceVideos.removeValue(forKey: cameraId)
    }

    private func makeBlackSampleBuffer(realSampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        if blackImageBuffer == nil || blackFormatDescription == nil {
            let width = 1280
            let height = 720
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: UInt(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(width),
                kCVPixelBufferHeightKey as String: Int(height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                pixelBufferAttributes as NSDictionary?,
                &blackPixelBufferPool
            )
            guard let blackPixelBufferPool else {
                return realSampleBuffer
            }
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, blackPixelBufferPool, &blackImageBuffer)
            guard let blackImageBuffer else {
                return realSampleBuffer
            }
            let image = createBlackImage(width: Double(width), height: Double(height))
            CIContext().render(image, to: blackImageBuffer)
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: blackImageBuffer,
                formatDescriptionOut: &blackFormatDescription
            )
            guard blackFormatDescription != nil else {
                return realSampleBuffer
            }
        }
        var timing = CMSampleTimingInfo(
            duration: realSampleBuffer.duration,
            presentationTimeStamp: realSampleBuffer.presentationTimeStamp,
            decodeTimeStamp: realSampleBuffer.decodeTimeStamp
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: blackImageBuffer!,
            formatDescription: blackFormatDescription!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else {
            return realSampleBuffer
        }
        return sampleBuffer
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, isFirstAfterAttach: Bool, skipEffects: Bool) {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        sampleBuffer.setAttachmentDisplayImmediately()
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
        if !effects.isEmpty && !skipEffects {
            let image = effect(imageBuffer, info: sampleBuffer)
            extent = image.extent
            if imageBuffer.width != Int(extent.width) || imageBuffer.height != Int(extent.height) {
                logger.info("effect image wrong size \(extent)")
                return
            }
            context.render(image, to: imageBuffer)
        }
        drawable?.enqueue(sampleBuffer, isFirstAfterAttach: isFirstAfterAttach)
        codec.appendImageBuffer(
            imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration
        )
        mixer?.recorder.appendPixelBuffer(
            imageBuffer,
            withPresentationTime: sampleBuffer.presentationTimeStamp
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
        drawable?.enqueue(nil, isFirstAfterAttach: false)
    }
}

extension IOVideoUnit: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ captureOutput: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        if capture.output == captureOutput {
            for replaceVideo in replaceVideos.values {
                replaceVideo.updateSampleBuffer(sampleBuffer.presentationTimeStamp.seconds)
            }
            var sampleBuffer = sampleBuffer
            if let selectedReplaceVideoCameraId {
                sampleBuffer = replaceVideos[selectedReplaceVideoCameraId]?
                    .getSampleBuffer(sampleBuffer) ?? makeBlackSampleBuffer(realSampleBuffer: sampleBuffer)
            }
            latestSampleBuffer = sampleBuffer
            latestSampleBufferDate = Date()
            if firstFrameDate == nil {
                firstFrameDate = latestSampleBufferDate
                return
            }
            guard latestSampleBufferDate!
                .timeIntervalSince(firstFrameDate!) > ioVideoUnitIgnoreFramesAfterAttachSeconds
            else {
                return
            }
            guard mixer?.useSampleBuffer(sampleBuffer: sampleBuffer, mediaType: AVMediaType.video) == true
            else {
                return
            }
            appendSampleBuffer(sampleBuffer, isFirstAfterAttach: isFirstAfterAttach, skipEffects: false)
            isFirstAfterAttach = false
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

private func createBlackImage(width: Double, height: Double) -> CIImage {
    UIGraphicsBeginImageContext(CGSize(width: width, height: height))
    let context = UIGraphicsGetCurrentContext()!
    context.setFillColor(UIColor.black.cgColor)
    context.fill([
        CGRect(x: 0, y: 0, width: width, height: height),
    ])
    let image = CIImage(image: UIGraphicsGetImageFromCurrentImageContext()!)!
    UIGraphicsEndImageContext()
    return image
}
