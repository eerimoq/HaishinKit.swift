import AVFoundation
import CoreImage
import CoreMedia
import UIKit

/// The interface a NetStream uses to inform its delegate.
public protocol NetStreamDelegate: AnyObject {
    /// Tells the receiver to session was interrupted.
    func stream(
        _ stream: NetStream,
        sessionWasInterrupted session: AVCaptureSession,
        reason: AVCaptureSession.InterruptionReason?
    )
    /// Tells the receiver to session interrupted ended.
    func stream(_ stream: NetStream, sessionInterruptionEnded session: AVCaptureSession)
    /// Tells the receiver to video codec error occured.
    func stream(_ stream: NetStream, videoCodecErrorOccurred error: VideoCodec.Error)
    /// Tells the receiver to audio codec error occured.
    func stream(_ stream: NetStream, audioCodecErrorOccurred error: AudioCodec.Error)
    /// Tells the receiver to will drop video frame.
    func streamWillDropFrame(_ stream: NetStream) -> Bool
    /// Tells the receiver to the stream opened.
    func streamDidOpen(_ stream: NetStream)
    func stream(
        _ stream: NetStream,
        audioLevel: Float,
        numberOfAudioChannels: Int,
        presentationTimestamp: Double
    )
    func streamVideo(_ stream: NetStream, presentationTimestamp: Double)
    func streamVideo(_ stream: NetStream, failedEffect: String?)
    func streamVideo(_ stream: NetStream, lowFpsImage: Data?)
    func stream(_ stream: NetStream, recorderErrorOccured error: IORecorder.Error)
    func stream(_ stream: NetStream, recorderFinishWriting writer: AVAssetWriter)
}

open class NetStream: NSObject {
    public let lockQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.haishinkit.HaishinKit.NetStream.lock")
        queue.setSpecific(key: queueKey, value: queueValue)
        return queue
    }()

    private static let queueKey = DispatchSpecificKey<UnsafeMutableRawPointer>()
    private static let queueValue = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    /// The mixer object.
    public private(set) lazy var mixer: IOMixer = {
        let mixer = IOMixer()
        mixer.delegate = self
        return mixer
    }()

    /// Specifies the delegate of the NetStream.
    public weak var delegate: (any NetStreamDelegate)?

    /// Specifiet the device torch indicating wheter the turn on(TRUE) or not(FALSE).
    public func setTorch(value: Bool) {
        lockQueue.async {
            self.mixer.video.torch = value
        }
    }

    public func setFrameRate(value: Float64) {
        lockQueue.async {
            self.mixer.video.frameRate = value
        }
    }

    /// Specifies if appleLog should be used.
    public func setColorSpace(colorSpace: AVCaptureColorSpace, onComplete: @escaping () -> Void) {
        lockQueue.async {
            self.mixer.video.colorSpace = colorSpace
            onComplete()
        }
    }

    public func setSessionPreset(preset: AVCaptureSession.Preset) {
        lockQueue.async {
            self.mixer.sessionPreset = preset
        }
    }

    public func setVideoOrientation(value: AVCaptureVideoOrientation) {
        mixer.video.videoOrientation = value
    }

    public func setHasAudio(value: Bool) {
        mixer.audio.muted = !value
    }

    public var audioSettings: AudioCodecSettings {
        get {
            mixer.audio.codec.settings
        }
        set {
            mixer.audio.codec.settings = newValue
        }
    }

    public var videoSettings: VideoCodecSettings {
        get {
            mixer.video.codec.settings
        }
        set {
            mixer.video.codec.settings = newValue
        }
    }

    public func attachCamera(
        _ device: AVCaptureDevice?,
        onError: ((_ error: Error) -> Void)? = nil,
        onSuccess: (() -> Void)? = nil,
        replaceVideoCameraId: UUID? = nil
    ) {
        lockQueue.async {
            do {
                try self.mixer.attachCamera(device, replaceVideoCameraId)
                onSuccess?()
            } catch {
                onError?(error)
            }
        }
    }

    public func attachAudio(
        _ device: AVCaptureDevice?,
        onError: ((_ error: Error) -> Void)? = nil
    ) {
        lockQueue.sync {
            do {
                try self.mixer.attachAudio(device)
            } catch {
                onError?(error)
            }
        }
    }

    public func addReplaceVideoSampleBuffer(id: UUID, _ sampleBuffer: CMSampleBuffer) {
        mixer.video.lockQueue.async {
            self.mixer.video.addReplaceVideoSampleBuffer(id: id, sampleBuffer)
        }
    }

    public func addReplaceVideo(cameraId: UUID, latency: Double) {
        mixer.video.lockQueue.async {
            self.mixer.video.addReplaceVideo(cameraId: cameraId, latency: latency)
        }
    }

    public func removeReplaceVideo(cameraId: UUID) {
        mixer.video.lockQueue.async {
            self.mixer.video.removeReplaceVideo(cameraId: cameraId)
        }
    }

    public func videoCapture() -> IOVideoUnit? {
        return mixer.video.lockQueue.sync {
            self.mixer.video
        }
    }

    /// Register a video effect.
    public func registerVideoEffect(_ effect: VideoEffect) -> Bool {
        mixer.video.lockQueue.sync {
            self.mixer.video.registerEffect(effect)
        }
    }

    /// Unregister a video effect.
    public func unregisterVideoEffect(_ effect: VideoEffect) -> Bool {
        mixer.video.lockQueue.sync {
            self.mixer.video.unregisterEffect(effect)
        }
    }

    public func setLowFpsImage(enabled: Bool) {
        mixer.video.lockQueue.sync {
            self.mixer.video.setLowFpsImage(enabled: enabled)
        }
    }

    public func startRecording(
        url: URL,
        _ settings: [AVMediaType: [String: Any]] = IORecorder.defaultOutputSettings
    ) {
        mixer.recorder.url = url
        mixer.recorder.outputSettings = settings
        mixer.recorder.startRunning()
    }

    public func stopRecording() {
        mixer.recorder.stopRunning()
    }
}

extension NetStream: IOMixerDelegate {
    func mixer(
        _: IOMixer,
        sessionWasInterrupted session: AVCaptureSession,
        reason: AVCaptureSession.InterruptionReason?
    ) {
        delegate?.stream(self, sessionWasInterrupted: session, reason: reason)
    }

    func mixer(_: IOMixer, sessionInterruptionEnded session: AVCaptureSession) {
        delegate?.stream(self, sessionInterruptionEnded: session)
    }

    func mixer(_: IOMixer, audioLevel: Float, numberOfAudioChannels: Int, presentationTimestamp: Double) {
        delegate?.stream(
            self,
            audioLevel: audioLevel,
            numberOfAudioChannels: numberOfAudioChannels,
            presentationTimestamp: presentationTimestamp
        )
    }

    func mixerVideo(_: IOMixer, presentationTimestamp: Double) {
        delegate?.streamVideo(self, presentationTimestamp: presentationTimestamp)
    }

    func mixerVideo(_: IOMixer, failedEffect: String?) {
        delegate?.streamVideo(self, failedEffect: failedEffect)
    }

    func mixerVideo(_: IOMixer, lowFpsImage: Data?) {
        delegate?.streamVideo(self, lowFpsImage: lowFpsImage)
    }

    func mixer(_: IOMixer, recorderErrorOccured error: IORecorder.Error) {
        delegate?.stream(self, recorderErrorOccured: error)
    }

    func mixer(_: IOMixer, recorderFinishWriting writer: AVAssetWriter) {
        delegate?.stream(self, recorderFinishWriting: writer)
    }
}
