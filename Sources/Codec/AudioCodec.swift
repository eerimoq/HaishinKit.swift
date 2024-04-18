import AVFoundation

public protocol AudioCodecDelegate: AnyObject {
    /// Tells the receiver to output an AVAudioFormat.
    func audioCodec(didOutput audioFormat: AVAudioFormat)
    /// Tells the receiver to output an encoded or decoded CMSampleBuffer.
    func audioCodec(didOutput audioBuffer: AVAudioBuffer, presentationTimeStamp: CMTime)
    /// Tells the receiver to occured an error.
    func audioCodec(errorOccurred error: AudioCodec.Error)
}

/**
 * The AudioCodec translate audio data to another format.
 * - seealso: https://developer.apple.com/library/ios/technotes/tn2236/_index.html
 */
public class AudioCodec {
    /// The AudioCodec  error domain codes.
    public enum Error: Swift.Error {
        case failedToCreate(from: AVAudioFormat, to: AVAudioFormat)
        case failedToConvert(error: NSError)
    }

    init(lockQueue: DispatchQueue) {
        self.lockQueue = lockQueue
    }

    static func makeAudioFormat(_ inSourceFormat: inout AudioStreamBasicDescription) -> AVAudioFormat? {
        if inSourceFormat.mFormatID == kAudioFormatLinearPCM,
           kLinearPCMFormatFlagIsBigEndian ==
           (inSourceFormat.mFormatFlags & kLinearPCMFormatFlagIsBigEndian)
        {
            // ReplayKit audioApp.
            guard inSourceFormat.mBitsPerChannel == 16 else {
                return nil
            }
            if let layout = makeChannelLayout(inSourceFormat.mChannelsPerFrame) {
                return .init(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: inSourceFormat.mSampleRate,
                    interleaved: true,
                    channelLayout: layout
                )
            }
            return AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: inSourceFormat.mSampleRate,
                channels: inSourceFormat.mChannelsPerFrame,
                interleaved: true
            )
        }
        if let layout = makeChannelLayout(inSourceFormat.mChannelsPerFrame) {
            return .init(streamDescription: &inSourceFormat, channelLayout: layout)
        }
        return .init(streamDescription: &inSourceFormat)
    }

    static func makeChannelLayout(_ numberOfChannels: UInt32) -> AVAudioChannelLayout? {
        guard numberOfChannels > 2 else {
            return nil
        }
        return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | numberOfChannels)
    }

    public weak var delegate: (any AudioCodecDelegate)?
    public private(set) var isRunning: Atomic<Bool> = .init(false)
    public var outputSettings: AudioCodecOutputSettings = .default {
        didSet {
            guard let audioConverter else {
                return
            }
            outputSettings.apply(audioConverter, oldValue: oldValue)
        }
    }

    private var lockQueue: DispatchQueue
    var inSourceFormat: AudioStreamBasicDescription? {
        didSet {
            guard var inSourceFormat, inSourceFormat != oldValue else {
                return
            }
            outputBuffers.removeAll()
            ringBuffer = .init(&inSourceFormat)
            audioConverter = makeAudioConverter(&inSourceFormat)
        }
    }

    private var ringBuffer: AudioCodecRingBuffer?
    private var outputBuffers: [AVAudioBuffer] = []
    private var audioConverter: AVAudioConverter?

    public func appendSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        _ presentationTimeStamp: CMTime,
        offset: Int = 0
    ) {
        guard isRunning.value else {
            return
        }
        switch outputSettings.format {
        case .aac:
            appendSampleBufferOutputAac(sampleBuffer, presentationTimeStamp, offset: offset)
        case .pcm:
            appendSampleBufferOutputPcm(sampleBuffer, presentationTimeStamp)
        }
    }

    private func appendSampleBufferOutputAac(
        _ sampleBuffer: CMSampleBuffer,
        _ presentationTimeStamp: CMTime,
        offset: Int
    ) {
        guard let audioConverter, let ringBuffer else {
            logger.info("audioConverter or ringBuffer missing")
            return
        }
        let numSamples = ringBuffer.appendSampleBuffer(
            sampleBuffer,
            presentationTimeStamp,
            offset: offset
        )
        if ringBuffer.isReady {
            guard let outputBuffer = allocOutputBuffer(audioConverter) else {
                logger.info("no output buffer")
                return
            }
            defer {
                freeOutputBuffer(outputBuffer)
            }
            convertBuffer(
                audioConverter: audioConverter,
                inputBuffer: ringBuffer.current,
                outputBuffer: outputBuffer,
                presentationTimeStamp: ringBuffer.latestPresentationTimeStamp
            )
            ringBuffer.next()
        }
        if offset + numSamples < sampleBuffer.numSamples {
            appendSampleBuffer(sampleBuffer, presentationTimeStamp, offset: offset + numSamples)
        }
    }

    private func appendSampleBufferOutputPcm(_ sampleBuffer: CMSampleBuffer,
                                             _ presentationTimeStamp: CMTime)
    {
        var offset = 0
        var newPresentationTimeStamp = presentationTimeStamp
        for i in 0 ..< sampleBuffer.numSamples {
            guard let buffer = makeInputBuffer() as? AVAudioCompressedBuffer else {
                continue
            }
            let sampleSize = CMSampleBufferGetSampleSize(sampleBuffer, at: i)
            let byteCount = sampleSize - ADTSHeader.size
            buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(byteCount)
            )
            buffer.packetCount = 1
            buffer.byteLength = UInt32(byteCount)
            if let blockBuffer = sampleBuffer.dataBuffer {
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: offset + ADTSHeader.size,
                    dataLength: byteCount,
                    destination: buffer.data
                )
                appendAudioBuffer(buffer, presentationTimeStamp: newPresentationTimeStamp)
                newPresentationTimeStamp = CMTimeAdd(
                    newPresentationTimeStamp,
                    CMTime(
                        value: CMTimeValue(1024),
                        timescale: presentationTimeStamp.timescale
                    )
                )
                offset += sampleSize
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioBuffer, presentationTimeStamp: CMTime) {
        guard isRunning.value, let audioConverter, let outputBuffer = allocOutputBuffer(audioConverter) else {
            return
        }
        defer {
            freeOutputBuffer(outputBuffer)
        }
        convertBuffer(
            audioConverter: audioConverter,
            inputBuffer: audioBuffer,
            outputBuffer: outputBuffer,
            presentationTimeStamp: presentationTimeStamp
        )
    }

    private func convertBuffer(
        audioConverter: AVAudioConverter,
        inputBuffer: AVAudioBuffer,
        outputBuffer: AVAudioBuffer,
        presentationTimeStamp: CMTime
    ) {
        var error: NSError?
        audioConverter.convert(to: outputBuffer, error: &error) { _, status in
            status.pointee = .haveData
            return inputBuffer
        }
        if let error {
            delegate?.audioCodec(errorOccurred: .failedToConvert(error: error))
        } else {
            delegate?.audioCodec(didOutput: outputBuffer, presentationTimeStamp: presentationTimeStamp)
        }
    }

    func makeInputBuffer() -> AVAudioBuffer? {
        guard let inputFormat = audioConverter?.inputFormat else {
            return nil
        }
        switch inSourceFormat?.mFormatID {
        case kAudioFormatLinearPCM:
            return AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024)
        default:
            return AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: 1024)
        }
    }

    private func allocOutputBuffer(_ audioConverter: AVAudioConverter) -> AVAudioBuffer? {
        if outputBuffers.isEmpty {
            return outputSettings.format.makeAudioBuffer(audioConverter.outputFormat)
        }
        return outputBuffers.removeFirst()
    }

    func freeOutputBuffer(_ buffer: AVAudioBuffer) {
        outputBuffers.append(buffer)
    }

    private func makeAudioConverter(_ inSourceFormat: inout AudioStreamBasicDescription)
        -> AVAudioConverter?
    {
        guard
            let inputFormat = Self.makeAudioFormat(&inSourceFormat),
            let outputFormat = outputSettings.format.makeAudioFormat(inSourceFormat)
        else {
            return nil
        }
        logger.info("inputFormat: \(inputFormat)")
        logger.info("outputFormat: \(outputFormat)")
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            delegate?.audioCodec(errorOccurred: .failedToCreate(from: inputFormat, to: outputFormat))
            return nil
        }
        converter.channelMap = makeChannelMap(
            numberOfInputChannels: Int(inputFormat.channelCount),
            numberOfOutputChannels: Int(outputFormat.channelCount),
            outputToInputChannelsMap: outputSettings.channelsMap
        )
        outputSettings.apply(converter, oldValue: nil)
        delegate?.audioCodec(didOutput: outputFormat)
        return converter
    }

    public func startRunning() {
        lockQueue.async {
            guard !self.isRunning.value else {
                return
            }
            if let audioConverter = self.audioConverter {
                self.delegate?.audioCodec(didOutput: audioConverter.outputFormat)
            }
            self.isRunning.mutate { $0 = true }
        }
    }

    public func stopRunning() {
        lockQueue.async {
            self.inSourceFormat = nil
            self.audioConverter = nil
            self.ringBuffer = nil
            self.isRunning.mutate { $0 = false }
        }
    }
}
