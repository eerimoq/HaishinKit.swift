import AVFoundation

#if canImport(SwiftPMSupport)
    import SwiftPMSupport
#endif

public enum GeneratorMode {
    case off
    case squareWave
}

public var audioGeneratorMode: GeneratorMode = .off
public var squareWaveGeneratorAmplitude: Int16 = 200
public var squareWaveGeneratorInterval: UInt64 = 60

final class IOAudioUnit: NSObject, IOUnit {
    private static let defaultPresentationTimeStamp: CMTime = .invalid
    private static let sampleBuffersThreshold: Int = 1
    private var generatorCount: UInt64 = 0

    lazy var codec: AudioCodec = {
        var codec = AudioCodec()
        codec.lockQueue = lockQueue
        return codec
    }()

    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioIOUnit.lock")
    var soundTransform: SoundTransform = .init() {
        didSet {
            soundTransform.apply(mixer?.mediaLink.playerNode)
        }
    }

    var muted = false
    weak var mixer: IOMixer?
    private(set) var capture: IOAudioCaptureUnit = .init()
    private var inSourceFormat: AudioStreamBasicDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            presentationTimeStamp = Self.defaultPresentationTimeStamp
            codec.inSourceFormat = inSourceFormat
        }
    }

    private var presentationTimeStamp = IOAudioUnit.defaultPresentationTimeStamp

    func attachAudio(_ device: AVCaptureDevice?,
                     automaticallyConfiguresApplicationAudioSession: Bool) throws
    {
        guard let mixer else {
            return
        }
        mixer.audioSession.beginConfiguration()
        defer {
            mixer.audioSession.commitConfiguration()
        }
        try capture.attachDevice(device, audioUnit: self)
        mixer.audioSession
            .automaticallyConfiguresApplicationAudioSession = automaticallyConfiguresApplicationAudioSession
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, isFirstAfterAttach _: Bool) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let sampleBuffer = sampleBuffer.muted(muted) else {
            return
        }
        inSourceFormat = sampleBuffer.formatDescription?.streamBasicDescription?.pointee
        // Synchronization between video and audio, need to synchronize the gaps.
        let numGapSamples = numGapSamples(sampleBuffer)
        let numSampleBuffers = Int(numGapSamples / sampleBuffer.numSamples)
        if Self.sampleBuffersThreshold <= numSampleBuffers {
            var gapPresentationTimeStamp = presentationTimeStamp
            for i in 0 ... numSampleBuffers {
                let numSamples = numSampleBuffers == i ? numGapSamples % sampleBuffer
                    .numSamples : sampleBuffer.numSamples
                guard let gapSampleBuffer = CMAudioSampleBufferFactory.makeSampleBuffer(
                    sampleBuffer,
                    numSamples: numSamples,
                    presentationTimeStamp: gapPresentationTimeStamp
                ) else {
                    continue
                }
                codec.appendSampleBuffer(gapSampleBuffer)
                mixer?.recorder.appendSampleBuffer(gapSampleBuffer)
                gapPresentationTimeStamp = CMTimeAdd(gapPresentationTimeStamp, gapSampleBuffer.duration)
            }
        }
        codec.appendSampleBuffer(sampleBuffer)
        mixer?.recorder.appendSampleBuffer(sampleBuffer)
        presentationTimeStamp = sampleBuffer.presentationTimeStamp
    }

    func registerEffect(_ effect: AudioEffect) -> Bool {
        if codec.effects.contains(effect) {
            return false
        } else {
            codec.effects.append(effect)
            return true
        }
    }

    func unregisterEffect(_ effect: AudioEffect) -> Bool {
        if let index = codec.effects.firstIndex(of: effect) {
            codec.effects.remove(at: index)
            return true
        } else {
            return false
        }
    }

    private func numGapSamples(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let mSampleRate = inSourceFormat?.mSampleRate,
              presentationTimeStamp != Self.defaultPresentationTimeStamp
        else {
            return 0
        }
        let sampleRate = Int32(mSampleRate)
        // Device audioMic or ReplayKit audioMic.
        if presentationTimeStamp.timescale == sampleRate {
            return Int(sampleBuffer.presentationTimeStamp.value - presentationTimeStamp.value) - sampleBuffer
                .numSamples
        }
        // ReplayKit audioApp. PTS = {69426976806125/1000000000 = 69426.977}
        let diff = CMTime(
            seconds: sampleBuffer.presentationTimeStamp.seconds,
            preferredTimescale: sampleRate
        ) - CMTime(seconds: presentationTimeStamp.seconds, preferredTimescale: sampleRate)
        return Int(diff.value) - sampleBuffer.numSamples
    }

    private func generateSquareWave(sampleBuffer: CMSampleBuffer) {
        if let dataBuffer = sampleBuffer.dataBuffer {
            if var data = dataBuffer.data {
                for i in stride(from: 0, to: data.count, by: 2) {
                    var sample = data.getInt16(offset: i)
                    if (generatorCount % squareWaveGeneratorInterval) < 30 {
                        sample = squareWaveGeneratorAmplitude
                    } else {
                        sample = -squareWaveGeneratorAmplitude
                    }
                    data.setInt16(value: sample, offset: i)
                    generatorCount += 1
                }
                data.replaceBlockBuffer(blockBuffer: dataBuffer)
            }
        }
    }
}

extension IOAudioUnit: IOUnitEncoding {
    func startEncoding(_ delegate: any AVCodecDelegate) {
        codec.delegate = delegate
        codec.startRunning()
    }

    func stopEncoding() {
        codec.stopRunning()
        codec.delegate = nil
        inSourceFormat = nil
    }
}

extension IOAudioUnit: IOUnitDecoding {
    func startDecoding() {
        if let playerNode = mixer?.mediaLink.playerNode {
            mixer?.audioEngine?.attach(playerNode)
        }
        codec.delegate = self
        codec.startRunning()
    }

    func stopDecoding() {
        if let playerNode = mixer?.mediaLink.playerNode {
            mixer?.audioEngine?.detach(playerNode)
        }
        codec.stopRunning()
        codec.delegate = nil
        inSourceFormat = nil
    }
}

extension IOAudioUnit: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard mixer?.useSampleBuffer(sampleBuffer: sampleBuffer, mediaType: AVMediaType.audio) == true else {
            return
        }
        switch audioGeneratorMode {
        case .squareWave:
            generateSquareWave(sampleBuffer: sampleBuffer)
        default:
            break
        }
        if let mixer {
            var audioLevel: Float
            if muted {
                audioLevel = .nan
            } else if let channel = connection.audioChannels.first {
                audioLevel = channel.averagePowerLevel
            } else {
                audioLevel = 0.0
            }
            mixer.delegate?.mixer(mixer, audioLevel: audioLevel)
        }
        appendSampleBuffer(sampleBuffer, isFirstAfterAttach: false)
    }
}

extension IOAudioUnit: AudioCodecDelegate {
    func audioCodec(_: AudioCodec, errorOccurred error: AudioCodec.Error) {
        logger.info("Failed to convert audio with error: \(error)")
    }

    func audioCodec(_: AudioCodec, didOutput audioFormat: AVAudioFormat) {
        do {
            mixer?.audioFormat = audioFormat
            if let audioEngine = mixer?.audioEngine, audioEngine.isRunning == false {
                try audioEngine.start()
            }
        } catch {
            logger.error(error)
        }
    }

    func audioCodec(_: AudioCodec, didOutput audioBuffer: AVAudioBuffer, presentationTimeStamp _: CMTime) {
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer else {
            return
        }
        mixer?.mediaLink.enqueueAudio(audioBuffer)
    }
}
