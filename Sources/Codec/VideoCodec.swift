import AVFoundation
import CoreFoundation
import UIKit
import VideoToolbox

public protocol VideoCodecDelegate: AnyObject {
    /// Tells the receiver to set a formatDescription.
    func videoCodec(_ codec: VideoCodec, didOutput formatDescription: CMFormatDescription?)
    /// Tells the receiver to output an encoded or decoded sampleBuffer.
    func videoCodec(_ codec: VideoCodec, didOutput sampleBuffer: CMSampleBuffer)
    /// Tells the receiver to occured an error.
    func videoCodec(_ codec: VideoCodec, errorOccurred error: VideoCodec.Error)
    /// Tells the receiver to drop frame.
    func videoCodecWillDropFame(_ codec: VideoCodec) -> Bool
}

public class VideoCodec {
    public enum Error: Swift.Error {
        /// The VideoCodec failed to create the VTSession.
        case failedToCreate(status: OSStatus)
        /// The VideoCodec failed to prepare the VTSession.
        case failedToPrepare(status: OSStatus)
        /// The VideoCodec failed to encode a frame.
        case failedToEncodeFrame(status: OSStatus, gotBuffer: Bool = false)
        /// The VideoCodec failed to decode a frame.
        case failedToDecodeFrame(status: OSStatus, gotBuffer: Bool = false)
        /// The VideoCodec failed to set an option.
        case failedToSetOption(status: OSStatus, option: VTSessionOption)
    }

    public init() {}

    /// The videoCodec's attributes value.
    public static var defaultAttributes: [NSString: AnyObject]? = [
        kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
    ]

    /// Specifies the settings for a VideoCodec.
    public var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.invalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }

    /// The running value indicating whether the VideoCodec is running.
    public private(set) var isRunning: Atomic<Bool> = .init(false)

    var lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoCodec.lock")
    var expectedFrameRate = IOMixer.defaultFrameRate
    public var formatDescription: CMFormatDescription? {
        didSet {
            guard !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: oldValue) else {
                return
            }
            delegate?.videoCodec(self, didOutput: formatDescription)
        }
    }

    var needsSync: Atomic<Bool> = .init(true)
    var attributes: [NSString: AnyObject]? {
        guard VideoCodec.defaultAttributes != nil else {
            return nil
        }
        var attributes: [NSString: AnyObject] = [:]
        for (key, value) in VideoCodec.defaultAttributes ?? [:] {
            attributes[key] = value
        }
        attributes[kCVPixelBufferWidthKey] = NSNumber(value: settings.videoSize.width)
        attributes[kCVPixelBufferHeightKey] = NSNumber(value: settings.videoSize.height)
        return attributes
    }

    public weak var delegate: (any VideoCodecDelegate)?
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            invalidateSession = false
        }
    }

    private var invalidateSession = true

    func appendImageBuffer(_ imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime, duration: CMTime) {
        guard isRunning.value, !(delegate?.videoCodecWillDropFame(self) ?? false) else {
            return
        }
        if invalidateSession {
            session = makeVideoCompressionSession(self)
        }
        _ = session?.encodeFrame(
            imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration
        ) { [unowned self] status, _, sampleBuffer in
            guard let sampleBuffer, status == noErr else {
                delegate?.videoCodec(
                    self,
                    errorOccurred: .failedToEncodeFrame(status: status, gotBuffer: sampleBuffer != nil)
                )
                return
            }
            formatDescription = sampleBuffer.formatDescription
            delegate?.videoCodec(self, didOutput: sampleBuffer)
        }
    }

    public func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning.value else {
            return
        }
        if invalidateSession {
            session = makeVideoDecompressionSession(self)
            needsSync.mutate { $0 = true }
        }
        if !sampleBuffer.isNotSync {
            needsSync.mutate { $0 = false }
        }
        _ = session?
            .decodeFrame(sampleBuffer) { [
                unowned self
            ] status, _, imageBuffer, presentationTimeStamp, duration in
                guard let imageBuffer, status == noErr else {
                    self.delegate?.videoCodec(
                        self,
                        errorOccurred: .failedToDecodeFrame(status: status, gotBuffer: imageBuffer != nil)
                    )
                    return
                }
                var timingInfo = CMSampleTimingInfo(
                    duration: duration,
                    presentationTimeStamp: presentationTimeStamp,
                    decodeTimeStamp: sampleBuffer.decodeTimeStamp
                )
                var videoFormatDescription: CMVideoFormatDescription?
                var status = CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    formatDescriptionOut: &videoFormatDescription
                )
                guard status == noErr else {
                    delegate?.videoCodec(self, errorOccurred: .failedToDecodeFrame(status: status))
                    return
                }
                var sampleBuffer: CMSampleBuffer?
                status = CMSampleBufferCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: videoFormatDescription!,
                    sampleTiming: &timingInfo,
                    sampleBufferOut: &sampleBuffer
                )
                guard let buffer = sampleBuffer, status == noErr else {
                    delegate?.videoCodec(
                        self,
                        errorOccurred: .failedToDecodeFrame(status: status, gotBuffer: sampleBuffer != nil)
                    )
                    return
                }
                delegate?.videoCodec(self, didOutput: buffer)
            }
    }

    @objc
    private func applicationWillEnterForeground(_: Notification) {
        invalidateSession = true
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue)
        else {
            return
        }
        switch type {
        case .ended:
            invalidateSession = true
        default:
            break
        }
    }

    public func startRunning() {
        lockQueue.async {
            self.isRunning.mutate { $0 = true }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.didAudioSessionInterruption),
                name: AVAudioSession.interruptionNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.applicationWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
        }
    }

    public func stopRunning() {
        lockQueue.async {
            self.session = nil
            self.invalidateSession = true
            self.needsSync.mutate { $0 = true }
            self.formatDescription = nil
            NotificationCenter.default.removeObserver(
                self,
                name: AVAudioSession.interruptionNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
            self.isRunning.mutate { $0 = false }
        }
    }
}
