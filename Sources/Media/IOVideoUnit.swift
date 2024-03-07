import AVFoundation
import CoreImage
import UIKit

public var ioVideoUnitIgnoreFramesAfterAttachSeconds = 0.3
public var ioVideoUnitWatchInterval = 1.0

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

public final class IOVideoUnit: NSObject {
    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoIOComponent.lock")
    public private(set) var device: AVCaptureDevice?
    private var input: AVCaptureInput?
    private var output: AVCaptureVideoDataOutput?
    private var connection: AVCaptureConnection?
    private let context = CIContext()
    weak var drawable: (any NetStreamDrawable)?

    var formatDescription: CMVideoFormatDescription? {
        didSet {
            codec.formatDescription = formatDescription
        }
    }

    lazy var codec: VideoCodec = .init(lockQueue: lockQueue)
    weak var mixer: IOMixer?
    var muted = false
    private var effects: [VideoEffect] = []

    var frameRate = IOMixer.defaultFrameRate {
        didSet {
            setDeviceFormat(frameRate: frameRate, colorSpace: colorSpace)
        }
    }

    var colorSpace = AVCaptureColorSpace.sRGB {
        didSet {
            setDeviceFormat(frameRate: frameRate, colorSpace: colorSpace)
        }
    }

    var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            guard videoOrientation != oldValue else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.torch {
                    self.setTorchMode(.on)
                }
            }
            output?.connections
                .filter { $0.isVideoOrientationSupported }
                .forEach { $0.videoOrientation = videoOrientation }
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
    private var latestSampleBufferAppendTime = CMTime.zero
    private var lowFpsImageEnabled: Bool = false
    private var lowFpsImageLatest: Double = 0.0

    deinit {
        stopGapFillerTimer()
    }

    private func startGapFillerTimer() {
        gapFillerTimer = DispatchSource.makeTimerSource(queue: lockQueue)
        let frameInterval = 1 / frameRate
        gapFillerTimer!.schedule(deadline: .now() + frameInterval, repeating: frameInterval)
        gapFillerTimer!.setEventHandler { [weak self] in
            self?.handleGapFillerTimer()
        }
        gapFillerTimer!.activate()
    }

    private func stopGapFillerTimer() {
        gapFillerTimer?.cancel()
        gapFillerTimer = nil
    }

    private func handleGapFillerTimer() {
        guard let latestSampleBufferDate else {
            return
        }
        let delta = Date().timeIntervalSince(latestSampleBufferDate)
        guard delta > 0.05 else {
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
        guard mixer?
            .useSampleBuffer(sampleBuffer!.presentationTimeStamp, mediaType: AVMediaType.video) == true
        else {
            return
        }
        _ = appendSampleBuffer(sampleBuffer!, isFirstAfterAttach: false, skipEffects: true)
    }

    func attach(_ device: AVCaptureDevice?, _ replaceVideo: UUID?) throws {
        startGapFillerTimer()
        let isOtherReplaceVideo = lockQueue.sync {
            let oldReplaceVideo = self.selectedReplaceVideoCameraId
            self.selectedReplaceVideoCameraId = replaceVideo
            return replaceVideo != oldReplaceVideo
        }
        guard let mixer else {
            return
        }
        if self.device == device {
            if isOtherReplaceVideo {
                lockQueue.sync {
                    firstFrameDate = nil
                    isFirstAfterAttach = true
                }
            }
            return
        }
        output?.setSampleBufferDelegate(nil, queue: lockQueue)
        let captureSession = mixer.captureSession
        if let device {
            mixer.mediaSync = .video
            try attachDevice(device, captureSession)
            lockQueue.sync {
                firstFrameDate = nil
                isFirstAfterAttach = true
            }
        } else {
            mixer.mediaSync = .passthrough
            try attachDevice(nil, captureSession)
            stopGapFillerTimer()
        }
        self.device = device
        output?.connections.forEach {
            if $0.isVideoMirroringSupported {
                $0.isVideoMirrored = isVideoMirrored
            }
            if $0.isVideoOrientationSupported {
                $0.videoOrientation = videoOrientation
            }
            if $0.isVideoStabilizationSupported {
                $0.preferredVideoStabilizationMode = preferredVideoStabilizationMode
            }
        }
        setDeviceFormat(frameRate: frameRate, colorSpace: colorSpace)
        output?.setSampleBufferDelegate(self, queue: lockQueue)
    }

    func effect(_ buffer: CVImageBuffer, info: CMSampleBuffer?) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        var failedEffect: String?
        for effect in effects {
            let effectOutputImage = effect.execute(image, info: info)
            if effectOutputImage.extent == extent {
                image = effectOutputImage
            } else {
                failedEffect = "\(effect.name) (wrong size)"
            }
        }
        if let mixer {
            mixer.delegate?.mixerVideo(mixer, failedEffect: failedEffect)
        }
        return image
    }

    func registerEffect(_ effect: VideoEffect) -> Bool {
        if effects.contains(effect) {
            return false
        } else {
            effects.append(effect)
            return true
        }
    }

    func unregisterEffect(_ effect: VideoEffect) -> Bool {
        if let index = effects.firstIndex(of: effect) {
            effects.remove(at: index)
            return true
        } else {
            return false
        }
    }

    func setLowFpsImage(enabled: Bool) {
        lowFpsImageEnabled = enabled
        lowFpsImageLatest = 0.0
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

    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, isFirstAfterAttach: Bool,
                                    skipEffects: Bool) -> Bool
    {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return false
        }
        if sampleBuffer.presentationTimeStamp < latestSampleBufferAppendTime {
            logger.info(
                """
                Discarding frame: \(sampleBuffer.presentationTimeStamp.seconds) \
                \(latestSampleBufferAppendTime.seconds)
                """
            )
            return false
        }
        if let mixer {
            mixer.delegate?.mixerVideo(
                mixer,
                presentationTimestamp: sampleBuffer.presentationTimeStamp.seconds
            )
        }
        latestSampleBufferAppendTime = sampleBuffer.presentationTimeStamp
        sampleBuffer.setAttachmentDisplayImmediately()
        imageBuffer.lockBaseAddress()
        defer {
            imageBuffer.unlockBaseAddress()
        }
        if !effects.isEmpty && !skipEffects {
            let image = effect(imageBuffer, info: sampleBuffer)
            if imageBuffer.width == Int(image.extent.width) && imageBuffer
                .height == Int(image.extent.height)
            {
                context.render(image, to: imageBuffer)
            }
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
        if lowFpsImageEnabled, let mixer,
           lowFpsImageLatest + ioVideoUnitWatchInterval < sampleBuffer.presentationTimeStamp.seconds
        {
            lowFpsImageLatest = sampleBuffer.presentationTimeStamp.seconds
            var ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let scale = 400.0 / Double(imageBuffer.width)
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cgImage = context.createCGImage(ciImage, from: ciImage.extent)!
            let image = UIImage(cgImage: cgImage)
            mixer.delegate?.mixerVideo(mixer, lowFpsImage: image.jpegData(compressionQuality: 0.3))
        }
        return true
    }

    func startEncoding(_ delegate: any AudioCodecDelegate & VideoCodecDelegate) {
        codec.delegate = delegate
        codec.startRunning()
    }

    func stopEncoding() {
        codec.stopRunning()
        codec.delegate = nil
    }

    public var isVideoMirrored = false {
        didSet {
            output?.connections.filter { $0.isVideoMirroringSupported }.forEach {
                $0.isVideoMirrored = isVideoMirrored
            }
        }
    }

    public var preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode = .off {
        didSet {
            output?.connections.filter { $0.isVideoStabilizationSupported }.forEach {
                $0.preferredVideoStabilizationMode = preferredVideoStabilizationMode
            }
        }
    }

    private func setDeviceFormat(frameRate: Float64, colorSpace: AVCaptureColorSpace) {
        guard let device, let mixer else {
            return
        }
        guard let format = device.findVideoFormat(
            width: mixer.sessionPreset.width!,
            height: mixer.sessionPreset.height!,
            frameRate: frameRate,
            colorSpace: colorSpace
        ) else {
            logger.info("No matching video format found")
            return
        }
        logger.info("Selected video format: \(format)")
        do {
            try device.lockForConfiguration()
            if device.activeFormat != format {
                device.activeFormat = format
            }
            device.activeColorSpace = colorSpace
            device.activeVideoMinFrameDuration = CMTime(
                value: 100,
                timescale: CMTimeScale(100 * frameRate)
            )
            device.activeVideoMaxFrameDuration = CMTime(
                value: 100,
                timescale: CMTimeScale(100 * frameRate)
            )
            device.unlockForConfiguration()
        } catch {
            logger.error("while locking device for fps:", error)
        }
    }

    private func attachDevice(_ device: AVCaptureDevice?, _ captureSession: AVCaptureSession) throws {
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
            if torch {
                setTorchMode(.on)
            }
        }
        if let connection, captureSession.connections.contains(connection) {
            captureSession.removeConnection(connection)
        }
        if let input, captureSession.inputs.contains(input) {
            captureSession.removeInput(input)
        }
        if let output, captureSession.outputs.contains(output) {
            captureSession.removeOutput(output)
        }
        if let device {
            input = try AVCaptureDeviceInput(device: device)
            output = AVCaptureVideoDataOutput()
            output!.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            ]
            if let port = input?.ports.first(where: { $0.mediaType == .video }) {
                connection = AVCaptureConnection(inputPorts: [port], output: output!)
            } else {
                connection = nil
            }
            if captureSession.canAddInput(input!) {
                captureSession.addInputWithNoConnections(input!)
            }
            if captureSession.canAddOutput(output!) {
                captureSession.addOutputWithNoConnections(output!)
            }
            if let connection, captureSession.canAddConnection(connection) {
                captureSession.addConnection(connection)
            }
            captureSession.automaticallyConfiguresCaptureDeviceForWideColor = false
        } else {
            input = nil
            output = nil
            connection = nil
        }
    }

    private func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        guard let device, device.isTorchModeSupported(torchMode) else {
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchMode
            device.unlockForConfiguration()
        } catch {
            logger.error("while setting torch:", error)
        }
    }
}

extension IOVideoUnit: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        for replaceVideo in replaceVideos.values {
            replaceVideo.updateSampleBuffer(sampleBuffer.presentationTimeStamp.seconds)
        }
        var sampleBuffer = sampleBuffer
        if let selectedReplaceVideoCameraId {
            sampleBuffer = replaceVideos[selectedReplaceVideoCameraId]?
                .getSampleBuffer(sampleBuffer) ?? makeBlackSampleBuffer(realSampleBuffer: sampleBuffer)
        }
        let now = Date()
        if firstFrameDate == nil {
            firstFrameDate = now
        }
        guard now.timeIntervalSince(firstFrameDate!) > ioVideoUnitIgnoreFramesAfterAttachSeconds
        else {
            return
        }
        latestSampleBuffer = sampleBuffer
        latestSampleBufferDate = now
        guard mixer?.useSampleBuffer(sampleBuffer.presentationTimeStamp, mediaType: AVMediaType.video) == true
        else {
            return
        }
        if appendSampleBuffer(sampleBuffer, isFirstAfterAttach: isFirstAfterAttach, skipEffects: false) {
            isFirstAfterAttach = false
        }
        stopGapFillerTimer()
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
