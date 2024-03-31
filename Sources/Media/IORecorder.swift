import AVFoundation
import SwiftPMSupport

/// The interface an IORecorder uses to inform its delegate.
public protocol IORecorderDelegate: AnyObject {
    /// Tells the receiver to recorder error occured.
    func recorder(_ recorder: IORecorder, errorOccured error: IORecorder.Error)
    /// Tells the receiver to finish writing.
    func recorder(_ recorder: IORecorder, finishWriting writer: AVAssetWriter)
}

/// The IORecorder class represents video and audio recorder.
public class IORecorder {
    /// The IORecorder error domain codes.
    public enum Error: Swift.Error {
        /// Failed to create the AVAssetWriter.
        case failedToCreateAssetWriter(error: Swift.Error)
        /// Failed to create the AVAssetWriterInput.
        case failedToCreateAssetWriterInput(error: NSException)
        /// Failed to append the PixelBuffer or SampleBuffer.
        case failedToAppend(error: Swift.Error?)
        /// Failed to finish writing the AVAssetWriter.
        case failedToFinishWriting(error: Swift.Error?)
    }

    public static let defaultAudioOutputSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 0,
        AVNumberOfChannelsKey: 0,
    ]

    public static let defaultVideoOutputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoHeightKey: 0,
        AVVideoWidthKey: 0,
    ]

    public weak var delegate: (any IORecorderDelegate)?
    public var audioOutputSettings = IORecorder.defaultAudioOutputSettings
    public var videoOutputSettings = IORecorder.defaultVideoOutputSettings
    public private(set) var isRunning: Atomic<Bool> = .init(false)
    public var url: URL?

    private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.IORecorder.lock")
    private var isReadyForStartWriting: Bool {
        guard let writer else {
            return false
        }
        return writer.inputs.count == 2
    }

    private var writer: AVAssetWriter?
    private var writerInputs: [AVMediaType: AVAssetWriterInput] = [:]
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var dimensions: CMVideoDimensions = .init(width: 0, height: 0)

    public func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning.value else {
            return
        }
        lockQueue.async {
            self.appendAudioInner(sampleBuffer)
        }
    }

    private func appendAudioInner(_ sampleBuffer: CMSampleBuffer) {
        guard
            let writer,
            let input = makeAudioWriterInput(sourceFormatHint: sampleBuffer.formatDescription),
            isReadyForStartWriting
        else {
            return
        }
        switch writer.status {
        case .unknown:
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        default:
            break
        }
        guard input.isReadyForMoreMediaData else {
            return
        }
        if !input.append(sampleBuffer) {
            delegate?.recorder(self, errorOccured: .failedToAppend(error: writer.error))
        }
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
        switch writer.status {
        case .unknown:
            writer.startWriting()
            writer.startSession(atSourceTime: withPresentationTime)
        default:
            break
        }
        guard input.isReadyForMoreMediaData else {
            return
        }
        if !adaptor.append(pixelBuffer, withPresentationTime: withPresentationTime) {
            delegate?.recorder(self, errorOccured: .failedToAppend(error: writer.error))
        }
    }

    private func makeAudioWriterInput(sourceFormatHint: CMFormatDescription?) -> AVAssetWriterInput? {
        if let input = writerInputs[.audio] {
            return input
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
        return makeWriterInput(.audio, outputSettings, sourceFormatHint: sourceFormatHint)
    }

    private func makeVideoWriterInput() -> AVAssetWriterInput? {
        if let input = writerInputs[.video] {
            return input
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
        return makeWriterInput(.video, outputSettings, sourceFormatHint: nil)
    }

    private func makeWriterInput(_ mediaType: AVMediaType,
                                 _ outputSettings: [String: Any],
                                 sourceFormatHint: CMFormatDescription?) -> AVAssetWriterInput?
    {
        let mediaTypeString = mediaType == AVMediaType.audio ? "audio" : "video"
        logger.info("Output settings \(outputSettings) for \(mediaTypeString)")
        var input: AVAssetWriterInput?
        nstry {
            input = AVAssetWriterInput(
                mediaType: mediaType,
                outputSettings: outputSettings,
                sourceFormatHint: sourceFormatHint
            )
            input?.expectsMediaDataInRealTime = true
            self.writerInputs[mediaType] = input
            if let input {
                self.writer?.add(input)
            }
        } _: { exception in
            self.delegate?.recorder(self, errorOccured: .failedToCreateAssetWriterInput(error: exception))
        }
        return input
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
        for (_, input) in writerInputs {
            input.markAsFinished()
        }
        writer.finishWriting {
            self.delegate?.recorder(self, finishWriting: writer)
            self.writer = nil
            self.writerInputs.removeAll()
            self.pixelBufferAdaptor = nil
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
    }
}
