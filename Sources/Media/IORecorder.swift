import AVFoundation
import SwiftPMSupport

public protocol IORecorderDelegate: AnyObject {
    func recorder(_ recorder: IORecorder, errorOccured error: IORecorder.Error)
    func recorder(_ recorder: IORecorder, finishWriting writer: AVAssetWriter)
}

private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.IORecorder.lock")

public class IORecorder {
    public enum Error: Swift.Error {
        case failedToCreateAssetWriter(error: Swift.Error)
        case failedToCreateAssetWriterInput(error: NSException)
        case failedToAppend(error: Swift.Error?)
        case failedToFinishWriting(error: Swift.Error?)
    }

    private static let defaultAudioOutputSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 0,
        AVNumberOfChannelsKey: 0,
    ]

    private static let defaultVideoOutputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoHeightKey: 0,
        AVVideoWidthKey: 0,
    ]

    public weak var delegate: (any IORecorderDelegate)?
    public var audioOutputSettings = IORecorder.defaultAudioOutputSettings
    public var videoOutputSettings = IORecorder.defaultVideoOutputSettings
    public private(set) var isRunning: Atomic<Bool> = .init(false)
    public var url: URL?
    private var outputChannelsMap: [Int: Int] = [0: 0, 1: 1]

    private var isReadyForStartWriting: Bool {
        return writer?.inputs.count == 2
    }

    private var writer: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioConverter: AVAudioConverter?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var dimensions: CMVideoDimensions = .init(width: 0, height: 0)

    public func setAudioChannelsMap(map: [Int: Int]) {
        lockQueue.async {
            self.outputChannelsMap = map
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning.value else {
            return
        }
        lockQueue.async {
            self.appendAudioInner(sampleBuffer)
        }
    }

    private func appendAudioInner(_ sampleBuffer: CMSampleBuffer) {
        let sampleBuffer = convert(sampleBuffer)
        guard
            let writer,
            let input = makeAudioWriterInput(sourceFormatHint: sampleBuffer.formatDescription),
            isReadyForStartWriting
        else {
            return
        }
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        guard input.isReadyForMoreMediaData else {
            return
        }
        if !input.append(sampleBuffer) {
            delegate?.recorder(self, errorOccured: .failedToAppend(error: writer.error))
        }
    }

    private func convert(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        var sampleBuffer = sampleBuffer
        guard
            let converter = makeAudioConverter(sampleBuffer.formatDescription)
        else {
            return sampleBuffer
        }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: UInt32(sampleBuffer.numSamples)
        ) else {
            return sampleBuffer
        }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard #available(iOS 15.0, *) else {
                    return
                }
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: converter.inputFormat,
                    bufferListNoCopy: list.unsafePointer
                ) else {
                    return
                }
                try converter.convert(to: outputBuffer, from: inputBuffer)
                sampleBuffer = outputBuffer
                    .makeSampleBuffer(presentationTimeStamp: sampleBuffer.presentationTimeStamp)!
            }
        } catch {}
        return sampleBuffer
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, withPresentationTime: CMTime) {
        guard isRunning.value else {
            return
        }
        lockQueue.async {
            self.appendVideoInner(pixelBuffer, withPresentationTime: withPresentationTime)
        }
    }

    private func appendVideoInner(_ pixelBuffer: CVPixelBuffer, withPresentationTime: CMTime) {
        if dimensions.width != pixelBuffer.width || dimensions.height != pixelBuffer.height {
            dimensions = .init(width: Int32(pixelBuffer.width), height: Int32(pixelBuffer.height))
        }
        guard
            let writer,
            let input = makeVideoWriterInput(),
            let adaptor = makePixelBufferAdaptor(input),
            isReadyForStartWriting
        else {
            return
        }
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: withPresentationTime)
        }
        guard input.isReadyForMoreMediaData else {
            return
        }
        if !adaptor.append(pixelBuffer, withPresentationTime: withPresentationTime) {
            delegate?.recorder(self, errorOccured: .failedToAppend(error: writer.error))
        }
    }

    private func makeAudioWriterInput(sourceFormatHint: CMFormatDescription?) -> AVAssetWriterInput? {
        if let audioWriterInput {
            return audioWriterInput
        }
        var outputSettings: [String: Any] = [:]
        if let sourceFormatHint,
           let inSourceFormat = sourceFormatHint.streamBasicDescription?.pointee
        {
            for (key, value) in audioOutputSettings {
                switch key {
                case AVSampleRateKey:
                    outputSettings[key] = isZero(value) ? inSourceFormat.mSampleRate : value
                case AVNumberOfChannelsKey:
                    outputSettings[key] = isZero(value) ? min(Int(inSourceFormat.mChannelsPerFrame), 2) :
                        value
                default:
                    outputSettings[key] = value
                }
            }
        }
        audioWriterInput = makeWriterInput(.audio, outputSettings, sourceFormatHint: sourceFormatHint)
        return audioWriterInput
    }

    private func makeVideoWriterInput() -> AVAssetWriterInput? {
        if let videoWriterInput {
            return videoWriterInput
        }
        var outputSettings: [String: Any] = [:]
        for (key, value) in videoOutputSettings {
            switch key {
            case AVVideoHeightKey:
                outputSettings[key] = isZero(value) ? Int(dimensions.height) : value
            case AVVideoWidthKey:
                outputSettings[key] = isZero(value) ? Int(dimensions.width) : value
            default:
                outputSettings[key] = value
            }
        }
        videoWriterInput = makeWriterInput(.video, outputSettings, sourceFormatHint: nil)
        return videoWriterInput
    }

    private func makeWriterInput(_ mediaType: AVMediaType,
                                 _ outputSettings: [String: Any],
                                 sourceFormatHint: CMFormatDescription?) -> AVAssetWriterInput?
    {
        var input: AVAssetWriterInput?
        nstry {
            input = AVAssetWriterInput(
                mediaType: mediaType,
                outputSettings: outputSettings,
                sourceFormatHint: sourceFormatHint
            )
            input?.expectsMediaDataInRealTime = true
            if let input {
                self.writer?.add(input)
            }
        } _: { exception in
            self.delegate?.recorder(self, errorOccured: .failedToCreateAssetWriterInput(error: exception))
        }
        return input
    }

    private func makeAudioConverter(_ formatDescription: CMFormatDescription?) -> AVAudioConverter? {
        guard audioConverter == nil else {
            return audioConverter
        }
        guard var streamBasicDescription = formatDescription?.streamBasicDescription?.pointee else {
            return nil
        }
        guard let inputFormat = makeAudioFormat(&streamBasicDescription) else {
            return nil
        }
        let outputNumberOfChannels = min(inputFormat.channelCount, 2)
        let outputFormat = AVAudioFormat(
            commonFormat: inputFormat.commonFormat,
            sampleRate: inputFormat.sampleRate,
            channels: outputNumberOfChannels,
            interleaved: inputFormat.isInterleaved
        )!
        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        audioConverter?.channelMap = makeChannelMap(
            numberOfInputChannels: Int(inputFormat.channelCount),
            numberOfOutputChannels: Int(outputNumberOfChannels),
            outputToInputChannelsMap: outputChannelsMap
        )
        return audioConverter
    }

    private func makeChannelLayout(_ numberOfChannels: UInt32) -> AVAudioChannelLayout? {
        guard numberOfChannels > 2 else {
            return nil
        }
        return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | numberOfChannels)
    }

    private func makeAudioFormat(_ basicDescription: inout AudioStreamBasicDescription) -> AVAudioFormat? {
        if basicDescription.mFormatID == kAudioFormatLinearPCM,
           kLinearPCMFormatFlagIsBigEndian ==
           (basicDescription.mFormatFlags & kLinearPCMFormatFlagIsBigEndian)
        {
            // ReplayKit audioApp.
            guard basicDescription.mBitsPerChannel == 16 else {
                return nil
            }
            if let layout = makeChannelLayout(basicDescription.mChannelsPerFrame) {
                return .init(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: basicDescription.mSampleRate,
                    interleaved: true,
                    channelLayout: layout
                )
            }
            return AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: basicDescription.mSampleRate,
                channels: basicDescription.mChannelsPerFrame,
                interleaved: true
            )
        }
        if let layout = makeChannelLayout(basicDescription.mChannelsPerFrame) {
            return .init(streamDescription: &basicDescription, channelLayout: layout)
        }
        return .init(streamDescription: &basicDescription)
    }

    private func makePixelBufferAdaptor(_ writerInput: AVAssetWriterInput)
        -> AVAssetWriterInputPixelBufferAdaptor?
    {
        if pixelBufferAdaptor != nil {
            return pixelBufferAdaptor
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [:]
        )
        pixelBufferAdaptor = adaptor
        return adaptor
    }

    public func startRunning() {
        lockQueue.async {
            self.startRunningInner()
        }
    }

    public func startRunningInner() {
        guard !isRunning.value, let url else {
            return
        }
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            isRunning.mutate { $0 = true }
        } catch {
            delegate?.recorder(self, errorOccured: .failedToCreateAssetWriter(error: error))
        }
    }

    public func stopRunning() {
        lockQueue.async {
            self.stopRunningInner()
        }
    }

    public func stopRunningInner() {
        guard isRunning.value else {
            return
        }
        finishWriting()
        isRunning.mutate { $0 = false }
    }

    private func finishWriting() {
        guard let writer, writer.status == .writing else {
            delegate?.recorder(self, errorOccured: .failedToFinishWriting(error: writer?.error))
            return
        }
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        audioWriterInput?.markAsFinished()
        videoWriterInput?.markAsFinished()
        writer.finishWriting {
            self.delegate?.recorder(self, finishWriting: writer)
            self.writer = nil
            self.audioWriterInput = nil
            self.videoWriterInput = nil
            self.pixelBufferAdaptor = nil
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
    }
}
