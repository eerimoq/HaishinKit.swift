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

    /// The default output settings for an IORecorder.
    public static let defaultOutputSettings: [AVMediaType: [String: Any]] = [
        .audio: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 0,
            AVNumberOfChannelsKey: 0,
        ],
        .video: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoHeightKey: 0,
            AVVideoWidthKey: 0,
        ],
    ]

    /// Specifies the delegate.
    public weak var delegate: (any IORecorderDelegate)?
    /// Specifies the recorder settings.
    public var outputSettings: [AVMediaType: [String: Any]] = IORecorder.defaultOutputSettings
    /// The running indicies whether recording or not.
    public private(set) var isRunning: Atomic<Bool> = .init(false)
    public var url: URL?

    private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.IORecorder.lock")
    private var isReadyForStartWriting: Bool {
        guard let writer else {
            return false
        }
        return outputSettings.count == writer.inputs.count
    }

    private var writer: AVAssetWriter?
    private var writerInputs: [AVMediaType: AVAssetWriterInput] = [:]
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioPresentationTime: CMTime = .zero
    private var videoPresentationTime: CMTime = .zero
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
        if input.append(sampleBuffer) {
            audioPresentationTime = sampleBuffer.presentationTimeStamp
        } else {
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
            isReadyForStartWriting,
            videoPresentationTime.seconds < withPresentationTime.seconds
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
        if adaptor.append(pixelBuffer, withPresentationTime: withPresentationTime) {
            videoPresentationTime = withPresentationTime
        } else {
            delegate?.recorder(self, errorOccured: .failedToAppend(error: writer.error))
        }
    }

    private func makeAudioWriterInput(sourceFormatHint: CMFormatDescription?) -> AVAssetWriterInput? {
        if let input = writerInputs[.audio] {
            return input
        }
        var outputSettings: [String: Any] = [:]
        if let defaultOutputSettings: [String: Any] = self.outputSettings[.audio],
           let format = sourceFormatHint,
           let inSourceFormat = format.streamBasicDescription?.pointee
        {
            for (key, value) in defaultOutputSettings {
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
        if let defaultOutputSettings: [String: Any] = self.outputSettings[.video] {
            for (key, value) in defaultOutputSettings {
                switch key {
                case AVVideoHeightKey:
                    outputSettings[key] = isZero(value) ? Int(dimensions.height) : value
                case AVVideoWidthKey:
                    outputSettings[key] = isZero(value) ? Int(dimensions.width) : value
                default:
                    outputSettings[key] = value
                }
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

    private func makePixelBufferAdaptor(_ writerInput: AVAssetWriterInput?)
        -> AVAssetWriterInputPixelBufferAdaptor?
    {
        guard pixelBufferAdaptor == nil else {
            return pixelBufferAdaptor
        }
        guard let writerInput = writerInput else {
            return nil
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
            guard !self.isRunning.value else {
                return
            }
            guard let url = self.url else {
                return
            }
            do {
                self.videoPresentationTime = .zero
                self.audioPresentationTime = .zero
                self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                self.isRunning.mutate { $0 = true }
            } catch {
                self.delegate?.recorder(self, errorOccured: .failedToCreateAssetWriter(error: error))
            }
        }
    }

    public func stopRunning() {
        lockQueue.async {
            guard self.isRunning.value else {
                return
            }
            self.finishWriting()
            self.isRunning.mutate { $0 = false }
        }
    }

    private func finishWriting() {
        guard let writer = writer, writer.status == .writing else {
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
