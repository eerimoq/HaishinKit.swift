import AVFoundation
import SwiftPMSupport

final class IOAudioUnit: NSObject {
    private static let defaultPresentationTimeStamp: CMTime = .invalid
    private static let sampleBuffersThreshold: Int = 1
    lazy var codec: AudioCodec = .init(lockQueue: lockQueue)
    private(set) var device: AVCaptureDevice?
    private var input: AVCaptureInput?
    private var output: AVCaptureAudioDataOutput?
    private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioIOUnit.lock")
    var muted = false
    weak var mixer: IOMixer?
    private var latestPresentationTimeStamp = IOAudioUnit.defaultPresentationTimeStamp

    private var inSourceFormat: AudioStreamBasicDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            latestPresentationTimeStamp = Self.defaultPresentationTimeStamp
            codec.inSourceFormat = inSourceFormat
        }
    }

    func attach(_ device: AVCaptureDevice?) throws {
        guard let mixer else {
            return
        }
        let captureSession = mixer.audioSession
        output?.setSampleBufferDelegate(nil, queue: lockQueue)
        try attachDevice(device, captureSession)
        self.device = device
        output?.setSampleBufferDelegate(self, queue: lockQueue)
        captureSession.automaticallyConfiguresApplicationAudioSession = false
    }

    func appendSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        _ presentationTimeStamp: CMTime,
        isFirstAfterAttach _: Bool
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let sampleBuffer = sampleBuffer.muted(muted) else {
            return
        }
        inSourceFormat = sampleBuffer.formatDescription?.streamBasicDescription?.pointee
        // Synchronization between video and audio, need to synchronize the gaps.
        let numGapSamples = numGapSamples(sampleBuffer, presentationTimeStamp)
        let numSampleBuffers = Int(numGapSamples / sampleBuffer.numSamples)
        if Self.sampleBuffersThreshold <= numSampleBuffers {
            var gapPresentationTimeStamp = latestPresentationTimeStamp
            for i in 0 ... numSampleBuffers {
                let numSamples = numSampleBuffers == i ? numGapSamples % sampleBuffer
                    .numSamples : sampleBuffer.numSamples
                guard let gapSampleBuffer = makeAudioSampleBuffer(
                    sampleBuffer,
                    numSamples: numSamples,
                    presentationTimeStamp: gapPresentationTimeStamp
                ) else {
                    continue
                }
                codec.appendSampleBuffer(gapSampleBuffer, gapPresentationTimeStamp)
                mixer?.recorder.appendAudio(gapSampleBuffer)
                gapPresentationTimeStamp = CMTimeAdd(gapPresentationTimeStamp, gapSampleBuffer.duration)
            }
        }
        codec.appendSampleBuffer(sampleBuffer, presentationTimeStamp)
        mixer?.recorder.appendAudio(sampleBuffer)
        latestPresentationTimeStamp = presentationTimeStamp
    }

    private func numGapSamples(_ sampleBuffer: CMSampleBuffer, _ presentationTimeStamp: CMTime) -> Int {
        guard let mSampleRate = inSourceFormat?.mSampleRate,
              latestPresentationTimeStamp != Self.defaultPresentationTimeStamp
        else {
            return 0
        }
        let sampleRate = Int32(mSampleRate)
        // Device audioMic or ReplayKit audioMic.
        if latestPresentationTimeStamp.timescale == sampleRate {
            return Int(presentationTimeStamp.value - latestPresentationTimeStamp.value) - sampleBuffer
                .numSamples
        }
        // ReplayKit audioApp. PTS = {69426976806125/1000000000 = 69426.977}
        let diff = CMTime(
            seconds: presentationTimeStamp.seconds,
            preferredTimescale: sampleRate
        ) - CMTime(seconds: latestPresentationTimeStamp.seconds, preferredTimescale: sampleRate)
        return Int(diff.value) - sampleBuffer.numSamples
    }

    func startEncoding(_ delegate: any AudioCodecDelegate & VideoCodecDelegate) {
        codec.delegate = delegate
        codec.startRunning()
    }

    func stopEncoding() {
        codec.stopRunning()
        codec.delegate = nil
        inSourceFormat = nil
    }

    private func attachDevice(_ device: AVCaptureDevice?, _ captureSession: AVCaptureSession) throws {
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }
        if let input, captureSession.inputs.contains(input) {
            captureSession.removeInput(input)
        }
        if let output, captureSession.outputs.contains(output) {
            captureSession.removeOutput(output)
        }
        if let device {
            input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input!) {
                captureSession.addInput(input!)
            }
            output = AVCaptureAudioDataOutput()
            if captureSession.canAddOutput(output!) {
                captureSession.addOutput(output!)
            }
        } else {
            input = nil
            output = nil
        }
    }
}

extension IOAudioUnit: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let mixer else {
            return
        }
        // Workaround for audio drift on iPhone 15 Pro Max running iOS 17. Probably issue on more models.
        let presentationTimeStamp = syncTimeToVideo(mixer: mixer, sampleBuffer: sampleBuffer)
        guard mixer.useSampleBuffer(presentationTimeStamp, mediaType: AVMediaType.audio) else {
            return
        }
        var audioLevel: Float
        if muted {
            audioLevel = .nan
        } else if let channel = connection.audioChannels.first {
            audioLevel = channel.averagePowerLevel
        } else {
            audioLevel = 0.0
        }
        mixer.delegate?.mixer(
            mixer,
            audioLevel: audioLevel,
            numberOfAudioChannels: connection.audioChannels.count,
            presentationTimestamp: presentationTimeStamp.seconds
        )
        appendSampleBuffer(sampleBuffer, presentationTimeStamp, isFirstAfterAttach: false)
    }
}

private func syncTimeToVideo(mixer: IOMixer, sampleBuffer: CMSampleBuffer) -> CMTime {
    var presentationTimeStamp = sampleBuffer.presentationTimeStamp
    if #available(iOS 16.0, *) {
        if let audioClock = mixer.audioSession.synchronizationClock,
           let videoClock = mixer.captureSession.synchronizationClock
        {
            let audioTimescale = sampleBuffer.presentationTimeStamp.timescale
            let seconds = audioClock.convertTime(presentationTimeStamp, to: videoClock).seconds
            let value = CMTimeValue(seconds * Double(audioTimescale))
            presentationTimeStamp = CMTime(value: value, timescale: audioTimescale)
        }
    }
    return presentationTimeStamp
}
