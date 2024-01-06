import AVFoundation
#if canImport(SwiftPMSupport)
    import SwiftPMSupport
#endif

import UIKit
extension AVCaptureSession.Preset {
    static let `default`: AVCaptureSession.Preset = .hd1280x720
}

protocol IOMixerDelegate: AnyObject {
    func mixer(
        _ mixer: IOMixer,
        sessionWasInterrupted session: AVCaptureSession,
        reason: AVCaptureSession.InterruptionReason?
    )
    func mixer(_ mixer: IOMixer, sessionInterruptionEnded session: AVCaptureSession)
    func mixer(_ mixer: IOMixer, audioLevel: Float)
}

/// An object that mixies audio and video for streaming.
public class IOMixer {
    /// The default fps for an IOMixer, value is 30.
    public static let defaultFrameRate: Float64 = 30
    /// The AVAudioEngine shared instance holder.
    public static let audioEngineHolder: InstanceHolder<AVAudioEngine> = .init {
        AVAudioEngine()
    }

    enum MediaSync {
        case video
        case passthrough
    }

    enum ReadyState {
        case standby
        case encoding
        case decoding
    }

    public var hasVideo: Bool {
        get {
            mediaLink.hasVideo
        }
        set {
            mediaLink.hasVideo = newValue
        }
    }

    public var isPaused: Bool {
        get {
            mediaLink.isPaused
        }
        set {
            mediaLink.isPaused = newValue
        }
    }

    var audioFormat: AVAudioFormat? {
        didSet {
            guard let audioEngine else {
                return
            }
            nstry({
                if let audioFormat = self.audioFormat {
                    audioEngine.connect(
                        self.mediaLink.playerNode,
                        to: audioEngine.mainMixerNode,
                        format: audioFormat
                    )
                } else {
                    audioEngine.disconnectNodeInput(self.mediaLink.playerNode)
                }
            }, { exeption in
                logger.warn(exeption)
            })
        }
    }

    private var readyState: ReadyState = .standby
    private(set) lazy var audioEngine: AVAudioEngine? = IOMixer.audioEngineHolder.retain()

    var isMultiCamSessionEnabled = false {
        didSet {
            guard oldValue != isMultiCamSessionEnabled else {
                return
            }
            logger.info("did set isMultiCamSessionEnabled to \(isMultiCamSessionEnabled)")
            videoSession = makeSession()
            audioSession = makeSession()
        }
    }

    var sessionPreset: AVCaptureSession.Preset = .default {
        didSet {
            guard sessionPreset != oldValue, videoSession.canSetSessionPreset(sessionPreset) else {
                return
            }
            videoSession.beginConfiguration()
            videoSession.sessionPreset = sessionPreset
            videoSession.commitConfiguration()
        }
    }

    public internal(set) lazy var videoSession: AVCaptureSession = makeSession() {
        didSet {
            if oldValue.isRunning {
                removeSessionObservers(oldValue)
                oldValue.stopRunning()
            }
            videoIO.capture.detachSession(oldValue)
            if videoSession.canSetSessionPreset(sessionPreset) {
                videoSession.sessionPreset = sessionPreset
            }
            videoIO.capture.attachSession(videoSession)
        }
    }

    public internal(set) lazy var audioSession: AVCaptureSession = makeSession() {
        didSet {
            if oldValue.isRunning {
                removeSessionObservers(oldValue)
                oldValue.stopRunning()
            }
            audioIO.capture.detachSession(oldValue)
            audioIO.capture.attachSession(audioSession)
        }
    }

    public private(set) var isRunning: Atomic<Bool> = .init(false)
    /// The recorder instance.
    public lazy var recorder = IORecorder()

    /// Specifies the drawable object.
    public weak var drawable: (any NetStreamDrawable)? {
        get {
            videoIO.drawable
        }
        set {
            videoIO.drawable = newValue
        }
    }

    var mediaSync = MediaSync.passthrough

    weak var delegate: (any IOMixerDelegate)?

    lazy var audioIO: IOAudioUnit = {
        var audioIO = IOAudioUnit()
        audioIO.mixer = self
        return audioIO
    }()

    lazy var videoIO: IOVideoUnit = {
        var videoIO = IOVideoUnit()
        videoIO.mixer = self
        return videoIO
    }()

    lazy var mediaLink: MediaLink = {
        var mediaLink = MediaLink()
        mediaLink.delegate = self
        return mediaLink
    }()

    deinit {
        if videoSession.isRunning {
            videoSession.stopRunning()
        }
        if audioSession.isRunning {
            audioSession.stopRunning()
        }
        IOMixer.audioEngineHolder.release(audioEngine)
    }

    private var audioTimeStamp = CMTime.zero
    private var videoTimeStamp = CMTime.zero

    /// Append a CMSampleBuffer with media type.
    public func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        switch readyState {
        case .encoding:
            break
        case .decoding:
            switch sampleBuffer.formatDescription?._mediaType {
            case kCMMediaType_Audio:
                audioIO.codec.appendSampleBuffer(sampleBuffer)
            case kCMMediaType_Video:
                videoIO.codec.formatDescription = sampleBuffer.formatDescription
                videoIO.codec.appendSampleBuffer(sampleBuffer)
            default:
                break
            }
        case .standby:
            break
        }
    }

    func useSampleBuffer(sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) -> Bool {
        switch mediaSync {
        case .video:
            if mediaType == .audio {
                return !videoTimeStamp.seconds.isZero && videoTimeStamp.seconds <= sampleBuffer
                    .presentationTimeStamp.seconds
            }
            if videoTimeStamp == CMTime.zero {
                videoTimeStamp = sampleBuffer.presentationTimeStamp
            }
            return true
        default:
            return true
        }
    }

    private func makeSession() -> AVCaptureSession {
        let session: AVCaptureSession
        if isMultiCamSessionEnabled {
            logger.info("Multi camera session")
            session = AVCaptureMultiCamSession()
        } else {
            logger.info("Single camera session")
            session = AVCaptureSession()
        }
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        } else {
            logger.info("Cannot set preset \(sessionPreset)")
        }
        return session
    }
}

extension IOMixer: IOUnitEncoding {
    /// Starts encoding for video and audio data.
    public func startEncoding(_ delegate: any AVCodecDelegate) {
        guard readyState == .standby else {
            return
        }
        readyState = .encoding
        videoIO.startEncoding(delegate)
        audioIO.startEncoding(delegate)
    }

    /// Stop encoding.
    public func stopEncoding() {
        guard readyState == .encoding else {
            return
        }
        videoTimeStamp = CMTime.zero
        audioTimeStamp = CMTime.zero
        videoIO.stopEncoding()
        audioIO.stopEncoding()
        readyState = .standby
    }
}

extension IOMixer: IOUnitDecoding {
    /// Starts decoding for video and audio data.
    public func startDecoding() {
        guard readyState == .standby else {
            return
        }
        audioIO.startDecoding()
        videoIO.startDecoding()
        mediaLink.startRunning()
        readyState = .decoding
    }

    /// Stop decoding.
    public func stopDecoding() {
        guard readyState == .decoding else {
            return
        }
        mediaLink.stopRunning()
        audioIO.stopDecoding()
        videoIO.stopDecoding()
        readyState = .standby
    }
}

extension IOMixer: MediaLinkDelegate {
    // MARK: MediaLinkDelegate

    func mediaLink(_: MediaLink, dequeue sampleBuffer: CMSampleBuffer) {
        drawable?.enqueue(sampleBuffer, isFirstAfterAttach: false)
    }

    func mediaLink(_: MediaLink, didBufferingChanged: Bool) {
        logger.info(didBufferingChanged)
    }
}

extension IOMixer: Running {
    // MARK: Running

    public func startRunning() {
        guard !isRunning.value else {
            return
        }
        addSessionObservers(videoSession)
        videoSession.startRunning()
        isRunning.mutate { $0 = videoSession.isRunning }
        addSessionObservers(audioSession)
        audioSession.startRunning()
        isRunning.mutate { $0 = audioSession.isRunning }
    }

    public func stopRunning() {
        guard isRunning.value else {
            return
        }
        removeSessionObservers(videoSession)
        videoSession.stopRunning()
        isRunning.mutate { $0 = videoSession.isRunning }
        removeSessionObservers(audioSession)
        audioSession.stopRunning()
        isRunning.mutate { $0 = audioSession.isRunning }
    }

    func startCaptureSessionIfNeeded() {
        guard isRunning.value else {
            return
        }
        if !videoSession.isRunning {
            videoSession.startRunning()
        }
        isRunning.mutate { $0 = videoSession.isRunning }
        if !audioSession.isRunning {
            audioSession.startRunning()
        }
        isRunning.mutate { $0 = audioSession.isRunning }
    }

    private func addSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )
    }

    private func removeSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.removeObserver(
            self,
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
    }

    @objc
    private func sessionRuntimeError(_ notification: NSNotification) {
        guard
            let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        else {
            return
        }
        let error = AVError(_nsError: errorValue)
        switch error.code {
        case .unsupportedDeviceActiveFormat:
            let isMultiCamSupported = videoSession is AVCaptureMultiCamSession
            guard let device = error.device, let format = device.videoFormat(
                width: sessionPreset.width ?? videoIO.codec.settings.videoSize.width,
                height: sessionPreset.height ?? videoIO.codec.settings.videoSize.height,
                frameRate: videoIO.frameRate,
                isMultiCamSupported: isMultiCamSupported
            ), device.activeFormat != format else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                if format.isFrameRateSupported(videoIO.frameRate) {
                    device.activeVideoMinFrameDuration = CMTime(
                        value: 100,
                        timescale: CMTimeScale(100 * videoIO.frameRate)
                    )
                    device.activeVideoMaxFrameDuration = CMTime(
                        value: 100,
                        timescale: CMTimeScale(100 * videoIO.frameRate)
                    )
                }
                device.unlockForConfiguration()
                videoSession.startRunning()
            } catch {
                logger.warn(error)
            }
        case .mediaServicesWereReset:
            startCaptureSessionIfNeeded()
        default:
            break
        }
    }

    @objc
    private func sessionWasInterrupted(_ notification: Notification) {
        guard let session = notification.object as? AVCaptureSession else {
            return
        }
        guard let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
              let reasonIntegerValue = userInfoValue.integerValue,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue)
        else {
            delegate?.mixer(self, sessionWasInterrupted: session, reason: nil)
            return
        }
        delegate?.mixer(self, sessionWasInterrupted: session, reason: reason)
    }

    @objc
    private func sessionInterruptionEnded(_: Notification) {
        delegate?.mixer(self, sessionInterruptionEnded: videoSession)
    }
}
