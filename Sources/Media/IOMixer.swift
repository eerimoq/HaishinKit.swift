import AVFoundation
import SwiftPMSupport
import SwiftUI

private func makeCaptureSession() -> AVCaptureSession {
    let session = AVCaptureSession()
    if #available(iOS 16.0, *) {
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
    }
    return session
}

protocol IOMixerDelegate: AnyObject {
    func mixer(
        _ mixer: IOMixer,
        sessionWasInterrupted session: AVCaptureSession,
        reason: AVCaptureSession.InterruptionReason?
    )
    func mixer(_ mixer: IOMixer, sessionInterruptionEnded session: AVCaptureSession)
    func mixer(_ mixer: IOMixer, audioLevel: Float, numberOfAudioChannels: Int, presentationTimestamp: Double)
    func mixerVideo(_ mixer: IOMixer, presentationTimestamp: Double)
    func mixerVideo(_ mixer: IOMixer, failedEffect: String?)
    func mixerVideo(_ mixer: IOMixer, lowFpsImage: Data?)
    func mixer(_ mixer: IOMixer, recorderErrorOccured error: IORecorder.Error)
    func mixer(_ mixer: IOMixer, recorderFinishWriting writer: AVAssetWriter)
}

/// An object that mixies audio and video for streaming.
public class IOMixer {
    public static let defaultFrameRate: Float64 = 30

    enum MediaSync {
        case video
        case passthrough
    }

    var sessionPreset: AVCaptureSession.Preset = .hd1280x720
    public let videoSession = makeCaptureSession()
    public let audioSession = makeCaptureSession()
    public private(set) var isRunning: Atomic<Bool> = .init(false)
    private var isEncoding = false

    public weak var drawable: (any NetStreamDrawable)? {
        get {
            video.drawable
        }
        set {
            video.drawable = newValue
        }
    }

    var mediaSync = MediaSync.passthrough
    weak var delegate: (any IOMixerDelegate)?
    private var videoTimeStamp = CMTime.zero

    lazy var audio: IOAudioUnit = {
        var audio = IOAudioUnit()
        audio.mixer = self
        return audio
    }()

    lazy var video: IOVideoUnit = {
        var video = IOVideoUnit()
        video.mixer = self
        return video
    }()

    lazy var recorder: IORecorder = {
        var recorder = IORecorder()
        recorder.delegate = self
        return recorder
    }()

    deinit {
        if videoSession.isRunning {
            videoSession.stopRunning()
        }
        if audioSession.isRunning {
            audioSession.stopRunning()
        }
    }

    func attachCamera(_ device: AVCaptureDevice?, _ replaceVideo: UUID?) throws {
        try video.attach(device, replaceVideo)
    }

    func attachAudio(_ device: AVCaptureDevice?) throws {
        try audio.attach(device)
    }

    func useSampleBuffer(_ presentationTimeStamp: CMTime, mediaType: AVMediaType) -> Bool {
        switch mediaSync {
        case .video:
            if mediaType == .audio {
                return !videoTimeStamp.seconds.isZero && videoTimeStamp.seconds <= presentationTimeStamp
                    .seconds
            }
            if videoTimeStamp == CMTime.zero {
                videoTimeStamp = presentationTimeStamp
            }
            return true
        default:
            return true
        }
    }

    public func startEncoding(_ delegate: any AudioCodecDelegate & VideoCodecDelegate) {
        guard !isEncoding else {
            return
        }
        isEncoding = true
        video.startEncoding(delegate)
        audio.startEncoding(delegate)
    }

    public func stopEncoding() {
        guard isEncoding else {
            return
        }
        videoTimeStamp = CMTime.zero
        video.stopEncoding()
        audio.stopEncoding()
        isEncoding = false
    }

    public func startRunning() {
        guard !isRunning.value else {
            return
        }
        addSessionObservers(videoSession)
        videoSession.startRunning()
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
        logger.info("sessionRuntimeError \(error)")
        /* switch error.code {
         case .unsupportedDeviceActiveFormat:
             guard let device = error.device, let format = device.findVideoFormat(
                 width: sessionPreset.width ?? video.codec.settings.videoSize.width,
                 height: sessionPreset.height ?? video.codec.settings.videoSize.height,
                 frameRate: video.frameRate,
                 colorSpace: .sRGB
             ), device.activeFormat != format else {
                 return
             }
             do {
                 try device.lockForConfiguration()
                 device.activeFormat = format
                 if format.isFrameRateSupported(video.frameRate) {
                     device.activeVideoMinFrameDuration = CMTime(
                         value: 100,
                         timescale: CMTimeScale(100 * video.frameRate)
                     )
                     device.activeVideoMaxFrameDuration = CMTime(
                         value: 100,
                         timescale: CMTimeScale(100 * video.frameRate)
                     )
                 }
                 device.unlockForConfiguration()
                 captureSession.startRunning()
             } catch {
                 logger.warn(error)
             }
         case .mediaServicesWereReset:
             startCaptureSessionIfNeeded()
         default:
             break
         } */
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

extension IOMixer: IORecorderDelegate {
    public func recorder(_: IORecorder, errorOccured error: IORecorder.Error) {
        delegate?.mixer(self, recorderErrorOccured: error)
    }

    public func recorder(_: IORecorder, finishWriting writer: AVAssetWriter) {
        delegate?.mixer(self, recorderFinishWriting: writer)
    }
}
