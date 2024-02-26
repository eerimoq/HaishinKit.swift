import AVFoundation

public protocol AudioCodecDelegate: AnyObject {
    /// Tells the receiver to output an AVAudioFormat.
    func audioCodec(_ codec: AudioCodec, didOutput audioFormat: AVAudioFormat)
    /// Tells the receiver to output an encoded or decoded CMSampleBuffer.
    func audioCodec(_ codec: AudioCodec, didOutput audioBuffer: AVAudioBuffer, presentationTimeStamp: CMTime)
    /// Tells the receiver to occured an error.
    func audioCodec(_ codec: AudioCodec, errorOccurred error: AudioCodec.Error)
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

    /// Creates a channel map for specific input and output format
    static func makeChannelMap(inChannels: Int, outChannels: Int,
                               outputChannelsMap: [Int: Int]) -> [NSNumber]
    {
        var result = Array(repeating: -1, count: outChannels)
        for inputIndex in 0 ..< min(inChannels, outChannels) {
            result[inputIndex] = inputIndex
        }
        for currentIndex in 0 ..< outChannels {
            if let inputIndex = outputChannelsMap[currentIndex], inputIndex < inChannels {
                result[currentIndex] = inputIndex
            }
        }
        return result.map { NSNumber(value: $0) }
    }

    /// Specifies the delegate.
    public weak var delegate: (any AudioCodecDelegate)?
    /// This instance is running to process(true) or not(false).
    public private(set) var isRunning: Atomic<Bool> = .init(false)
    /// Specifies the settings for audio codec.
    public var settings: AudioCodecSettings = .default {
        didSet {
            settings.apply(audioConverter, oldValue: oldValue)
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
        switch settings.format {
        case .aac:
            appendSampleBufferAac(sampleBuffer, presentationTimeStamp, offset: offset)
        case .pcm:
            appendSampleBufferPcm(sampleBuffer, presentationTimeStamp)
        case .opus:
            appendSampleBufferOpus(sampleBuffer, presentationTimeStamp, offset: offset)
        }
    }

    private func appendSampleBufferAac(
        _ sampleBuffer: CMSampleBuffer,
        _ presentationTimeStamp: CMTime,
        offset: Int = 0
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
            guard let buffer = getOutputBuffer() else {
                logger.info("no output buffer")
                return
            }
            convertBuffer(
                audioConverter: audioConverter,
                inputBuffer: ringBuffer.current,
                outputBuffer: buffer,
                presentationTimeStamp: ringBuffer.latestPresentationTimeStamp
            )
            ringBuffer.next()
        }
        if offset + numSamples < sampleBuffer.numSamples {
            appendSampleBuffer(sampleBuffer, presentationTimeStamp, offset: offset + numSamples)
        }
    }

    private func appendSampleBufferPcm(_ sampleBuffer: CMSampleBuffer, _ presentationTimeStamp: CMTime) {
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

    private func appendSampleBufferOpus(
        _ sampleBuffer: CMSampleBuffer,
        _ presentationTimeStamp: CMTime,
        offset: Int = 0
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
            guard let buffer = getOutputBuffer() else {
                logger.info("no output buffer")
                return
            }
            convertBuffer(
                audioConverter: audioConverter,
                inputBuffer: ringBuffer.current,
                outputBuffer: buffer,
                presentationTimeStamp: ringBuffer.latestPresentationTimeStamp
            )
            ringBuffer.next()
        }
        if offset + numSamples < sampleBuffer.numSamples {
            appendSampleBuffer(sampleBuffer, presentationTimeStamp, offset: offset + numSamples)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioBuffer, presentationTimeStamp: CMTime) {
        guard isRunning.value, let audioConverter, let buffer = getOutputBuffer() else {
            return
        }
        convertBuffer(
            audioConverter: audioConverter,
            inputBuffer: audioBuffer,
            outputBuffer: buffer,
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
            delegate?.audioCodec(self, errorOccurred: .failedToConvert(error: error))
        } else {
            delegate?.audioCodec(self, didOutput: outputBuffer, presentationTimeStamp: presentationTimeStamp)
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

    func releaseOutputBuffer(_ buffer: AVAudioBuffer) {
        outputBuffers.append(buffer)
    }

    private func getOutputBuffer() -> AVAudioBuffer? {
        guard let outputFormat = audioConverter?.outputFormat else {
            return nil
        }
        if outputBuffers.isEmpty {
            return settings.format.makeAudioBuffer(outputFormat)
        }
        return outputBuffers.removeFirst()
    }

    private func makeAudioConverter(_ inSourceFormat: inout AudioStreamBasicDescription)
        -> AVAudioConverter?
    {
        guard
            let inputFormat = Self.makeAudioFormat(&inSourceFormat),
            let outputFormat = settings.format.makeAudioFormat(inSourceFormat)
        else {
            logger.info("cannot create")
            return nil
        }
        logger.info("inputFormat: \(inputFormat)")
        logger.info("outputFormat: \(outputFormat)")
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            logger.info("Failed to create converter")
            delegate?.audioCodec(self, errorOccurred: .failedToCreate(from: inputFormat, to: outputFormat))
            return nil
        }
        let channelMap = Self.makeChannelMap(
            inChannels: Int(inputFormat.channelCount),
            outChannels: Int(outputFormat.channelCount),
            outputChannelsMap: settings.outputChannelsMap
        )
        logger.info("channelMap: \(channelMap)")
        converter.channelMap = channelMap
        settings.apply(converter, oldValue: nil)
        delegate?.audioCodec(self, didOutput: outputFormat)
        return converter
    }

    public func startRunning() {
        lockQueue.async {
            guard !self.isRunning.value else {
                return
            }
            if let audioConverter = self.audioConverter {
                self.delegate?.audioCodec(self, didOutput: audioConverter.outputFormat)
            }
            self.isRunning.mutate { $0 = true }
        }
    }

    public func stopRunning() {
        lockQueue.async {
            guard self.isRunning.value else {
                return
            }
            self.inSourceFormat = nil
            self.audioConverter = nil
            self.ringBuffer = nil
            self.isRunning.mutate { $0 = false }
        }
    }
}
