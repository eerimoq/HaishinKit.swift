import AVFoundation
import CoreMedia
import Foundation

#if canImport(SwiftPMSupport)
    import SwiftPMSupport
#endif

public var payloadSize: Int = 1316

/// The interface an MPEG-2 TS (Transport Stream) writer uses to inform its delegates.
public protocol TSWriterDelegate: AnyObject {
    func writer(_ writer: TSWriter, didRotateFileHandle timestamp: CMTime)
    func writer(_ writer: TSWriter, doOutput data: Data)
}

public extension TSWriterDelegate {
    // default implementation noop
    func writer(_: TSWriter, didRotateFileHandle _: CMTime) {
        // noop
    }
}

/// The TSWriter class represents writes MPEG-2 transport stream data.
public class TSWriter: Running {
    public static let defaultPATPID: UInt16 = 0
    public static let defaultPMTPID: UInt16 = 4095
    public static let defaultVideoPID: UInt16 = 256
    public static let defaultAudioPID: UInt16 = 257

    private static let audioStreamId: UInt8 = 192
    private static let videoStreamId: UInt8 = 224

    public static let defaultSegmentDuration: Double = 2

    /// The delegate instance.
    public weak var delegate: (any TSWriterDelegate)?
    /// This instance is running to process(true) or not(false).
    public internal(set) var isRunning: Atomic<Bool> = .init(false)
    /// The exptected medias = [.video, .audio].
    public var expectedMedias: Set<AVMediaType> = []

    var audioContinuityCounter: UInt8 = 0
    var videoContinuityCounter: UInt8 = 0
    var PCRPID: UInt16 = TSWriter.defaultVideoPID
    var rotatedTimestamp = CMTime.zero
    var segmentDuration: Double = TSWriter.defaultSegmentDuration
    private let outputLock: DispatchQueue = .init(
        label: "com.haishinkit.HaishinKit.TSWriter",
        qos: .userInitiated
    )

    private var videoData: [Data?] = [nil, nil]
    private var videoDataOffset: Int = 0

    private(set) var PAT: TSProgramAssociation = {
        let PAT: TSProgramAssociation = .init()
        PAT.programs = [1: TSWriter.defaultPMTPID]
        return PAT
    }()

    private(set) var PMT: TSProgramMap = .init()
    private var audioConfig: AudioSpecificConfig? {
        didSet {
            writeProgramIfNeeded()
        }
    }

    private var videoConfig: DecoderConfigurationRecord? {
        didSet {
            writeProgramIfNeeded()
        }
    }

    private var videoTimestamp: CMTime = .invalid
    private var audioTimestamp: CMTime = .invalid
    private var PCRTimestamp = CMTime.zero
    private var canWriteFor: Bool {
        return (expectedMedias.contains(.audio) == (audioConfig != nil))
            && (expectedMedias.contains(.video) == (videoConfig != nil))
    }

    public init(segmentDuration: Double = TSWriter.defaultSegmentDuration) {
        self.segmentDuration = segmentDuration
    }

    public func startRunning() {
        guard isRunning.value else {
            return
        }
        isRunning.mutate { $0 = true }
    }

    public func stopRunning() {
        guard !isRunning.value else {
            return
        }
        audioContinuityCounter = 0
        videoContinuityCounter = 0
        PCRPID = TSWriter.defaultVideoPID
        PAT.programs.removeAll()
        PAT.programs = [1: TSWriter.defaultPMTPID]
        PMT = TSProgramMap()
        audioConfig = nil
        videoConfig = nil
        videoTimestamp = .invalid
        audioTimestamp = .invalid
        PCRTimestamp = .invalid
        isRunning.mutate { $0 = false }
    }

    // swiftlint:disable:next function_parameter_count
    private func writeSampleBuffer(_ PID: UInt16,
                                   presentationTimeStamp: CMTime,
                                   decodeTimeStamp: CMTime,
                                   randomAccessIndicator: Bool,
                                   PES: PacketizedElementaryStream) -> Data?
    {
        let timestamp = decodeTimeStamp == .invalid ? presentationTimeStamp : decodeTimeStamp
        let packets: [TSPacket] = split(PID, PES: PES, timestamp: timestamp)
        packets[0].adaptationField?.randomAccessIndicator = randomAccessIndicator
        rotateFileHandle(timestamp)

        var bytes = Data()
        for var packet in packets {
            switch PID {
            case TSWriter.defaultAudioPID:
                packet.continuityCounter = audioContinuityCounter
                audioContinuityCounter = (audioContinuityCounter + 1) & 0x0F
            case TSWriter.defaultVideoPID:
                packet.continuityCounter = videoContinuityCounter
                videoContinuityCounter = (videoContinuityCounter + 1) & 0x0F
            default:
                break
            }
            bytes.append(packet.data)
        }

        return bytes
    }

    func rotateFileHandle(_ timestamp: CMTime) {
        let duration: Double = timestamp.seconds - rotatedTimestamp.seconds
        if duration <= segmentDuration {
            return
        }
        writeProgram()
        rotatedTimestamp = timestamp
        delegate?.writer(self, didRotateFileHandle: timestamp)
    }

    func write(_ data: Data) {
        outputLock.sync {
            self.writeBytes(data)
        }
    }

    private func writePacket(_ data: Data) {
        delegate?.writer(self, doOutput: data)
    }

    private func writeBytes(_ data: Data) {
        for packet in data.chunks(payloadSize) {
            writePacket(packet)
        }
    }

    private func appendVideoData(data: Data?) {
        videoData[0] = videoData[1]
        videoData[1] = data
        videoDataOffset = 0
    }

    private func writeVideo(data: Data) {
        outputLock.sync {
            if var videoData = videoData[0] {
                if videoDataOffset != 0 {
                    videoData = Data(videoData[videoDataOffset...])
                }
                self.writeBytes(videoData)
            }
            self.appendVideoData(data: data)
        }
    }

    private func writeAudio(data: Data) {
        outputLock.sync {
            if let videoData = videoData[0] {
                for var packet in data.chunks(payloadSize) {
                    let videoSize = payloadSize - packet.count
                    if videoSize > 0 {
                        let endOffset = min(videoDataOffset + videoSize, videoData.count)
                        if videoDataOffset != endOffset {
                            packet = videoData[videoDataOffset ..< endOffset] + packet
                            videoDataOffset = endOffset
                        }
                    }
                    self.writePacket(packet)
                }
                if videoDataOffset == videoData.count {
                    self.appendVideoData(data: nil)
                }
            } else {
                self.writeBytes(data)
            }
        }
    }

    final func writeProgram() {
        PMT.PCRPID = PCRPID
        var bytes = Data()
        var packets: [TSPacket] = []
        packets.append(contentsOf: PAT.arrayOfPackets(TSWriter.defaultPATPID))
        packets.append(contentsOf: PMT.arrayOfPackets(TSWriter.defaultPMTPID))
        for packet in packets {
            bytes.append(packet.data)
        }
        write(bytes)
    }

    final func writeProgramIfNeeded() {
        guard !expectedMedias.isEmpty else {
            return
        }
        guard canWriteFor else {
            return
        }
        writeProgram()
    }

    private func split(_ PID: UInt16, PES: PacketizedElementaryStream, timestamp: CMTime) -> [TSPacket] {
        var PCR: UInt64?
        let duration: Double = timestamp.seconds - PCRTimestamp.seconds
        if PCRPID == PID && duration >= 0.02 {
            PCR =
                UInt64((timestamp
                        .seconds - (PID == TSWriter.defaultVideoPID ? videoTimestamp : audioTimestamp)
                        .seconds) *
                    TSTimestamp.resolution)
            PCRTimestamp = timestamp
        }
        return PES.arrayOfPackets(PID, PCR: PCR)
    }
}

extension TSWriter: AudioCodecDelegate {
    public func audioCodec(_: AudioCodec, errorOccurred error: AudioCodec.Error) {
        logger.error("Audio error \(error)")
    }

    public func audioCodec(_: AudioCodec, didOutput outputFormat: AVAudioFormat) {
        logger.info("Audio setup \(outputFormat) (forcing AAC)")
        var data = ESSpecificData()
        data.streamType = .adtsAac
        data.elementaryPID = TSWriter.defaultAudioPID
        PMT.elementaryStreamSpecificData.append(data)
        audioContinuityCounter = 0
        audioConfig = AudioSpecificConfig(formatDescription: outputFormat.formatDescription)
    }

    public func audioCodec(
        _ codec: AudioCodec,
        didOutput audioBuffer: AVAudioBuffer,
        presentationTimeStamp: CMTime
    ) {
        guard let audioBuffer = audioBuffer as? AVAudioCompressedBuffer else {
            logger.info("Audio output no buffer")
            return
        }
        guard canWriteFor else {
            logger.info("Cannot write audio buffer")
            return
        }
        if audioTimestamp == .invalid {
            audioTimestamp = presentationTimeStamp
            if PCRPID == TSWriter.defaultAudioPID {
                PCRTimestamp = audioTimestamp
            }
        }

        guard let config = audioConfig else {
            return
        }

        guard var PES = PacketizedElementaryStream(
            bytes: audioBuffer.data.assumingMemoryBound(to: UInt8.self),
            count: audioBuffer.byteLength,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid,
            timestamp: audioTimestamp,
            config: config,
            streamID: TSWriter.audioStreamId
        ) else {
            return
        }

        if let bytes = writeSampleBuffer(
            TSWriter.defaultAudioPID,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid,
            randomAccessIndicator: true,
            PES: PES
        ) {
            writeAudio(data: bytes)
        }
        codec.releaseOutputBuffer(audioBuffer)
    }
}

extension TSWriter: VideoCodecDelegate {
    public func videoCodec(_: VideoCodec, didOutput formatDescription: CMFormatDescription?) {
        guard let formatDescription else {
            return
        }
        var data = ESSpecificData()
        data.elementaryPID = TSWriter.defaultVideoPID
        videoContinuityCounter = 0
        if let avcC = AVCDecoderConfigurationRecord.getData(formatDescription) {
            data.streamType = .h264
            PMT.elementaryStreamSpecificData.append(data)
            videoConfig = AVCDecoderConfigurationRecord(data: avcC)
        } else if let hvcC = HEVCDecoderConfigurationRecord.getData(formatDescription) {
            data.streamType = .h265
            PMT.elementaryStreamSpecificData.append(data)
            videoConfig = HEVCDecoderConfigurationRecord(data: hvcC)
        }
    }

    public func videoCodec(_: VideoCodec, didOutput sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = sampleBuffer.dataBuffer else {
            return
        }
        var length = 0
        var buffer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &buffer
        ) == noErr else {
            return
        }
        guard let buffer else {
            return
        }
        guard canWriteFor else {
            logger.info("Cannot write video buffer")
            return
        }
        if videoTimestamp == .invalid {
            videoTimestamp = sampleBuffer.presentationTimeStamp
            if PCRPID == TSWriter.defaultVideoPID {
                PCRTimestamp = videoTimestamp
            }
        }

        guard let config = videoConfig else {
            return
        }

        let randomAccessIndicator = !sampleBuffer.isNotSync
        let PES: PacketizedElementaryStream
        let bytes = UnsafeRawPointer(buffer).bindMemory(to: UInt8.self, capacity: length)

        if let config: AVCDecoderConfigurationRecord = config as? AVCDecoderConfigurationRecord {
            PES = PacketizedElementaryStream(
                bytes: bytes,
                count: UInt32(length),
                presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                decodeTimeStamp: sampleBuffer.decodeTimeStamp,
                timestamp: videoTimestamp,
                config: randomAccessIndicator ? config : nil,
                streamID: TSWriter.videoStreamId
            )
        } else if let config: HEVCDecoderConfigurationRecord = config as? HEVCDecoderConfigurationRecord {
            PES = PacketizedElementaryStream(
                bytes: bytes,
                count: UInt32(length),
                presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                decodeTimeStamp: sampleBuffer.decodeTimeStamp,
                timestamp: videoTimestamp,
                config: randomAccessIndicator ? config : nil,
                streamID: TSWriter.videoStreamId
            )
        } else {
            return
        }

        if let bytes = writeSampleBuffer(
            TSWriter.defaultVideoPID,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            decodeTimeStamp: sampleBuffer.decodeTimeStamp,
            randomAccessIndicator: randomAccessIndicator,
            PES: PES
        ) {
            writeVideo(data: bytes)
        }
    }

    public func videoCodec(_: VideoCodec, errorOccurred error: VideoCodec.Error) {
        logger.error("Video error \(error)")
    }

    public func videoCodecWillDropFame(_: VideoCodec) -> Bool {
        return false
    }
}

class TSFileWriter: TSWriter {
    static let defaultSegmentCount: Int = 3
    static let defaultSegmentMaxCount: Int = 12

    var segmentMaxCount: Int = TSFileWriter.defaultSegmentMaxCount
    private(set) var files: [M3UMediaInfo] = []
    private var currentFileHandle: FileHandle?
    private var currentFileURL: URL?
    private var sequence: Int = 0

    var playlist: String {
        var m3u8 = M3U()
        m3u8.targetDuration = segmentDuration
        if sequence <= TSFileWriter.defaultSegmentMaxCount {
            m3u8.mediaSequence = 0
            m3u8.mediaList = files
            for mediaItem in m3u8.mediaList where mediaItem.duration > m3u8.targetDuration {
                m3u8.targetDuration = mediaItem.duration + 1
            }
            return m3u8.description
        }
        let startIndex = max(0, files.count - TSFileWriter.defaultSegmentCount)
        m3u8.mediaSequence = sequence - TSFileWriter.defaultSegmentMaxCount
        m3u8.mediaList = Array(files[startIndex ..< files.count])
        for mediaItem in m3u8.mediaList where mediaItem.duration > m3u8.targetDuration {
            m3u8.targetDuration = mediaItem.duration + 1
        }
        return m3u8.description
    }

    override func rotateFileHandle(_ timestamp: CMTime) {
        let duration: Double = timestamp.seconds - rotatedTimestamp.seconds
        if duration <= segmentDuration {
            return
        }
        let fileManager = FileManager.default

        #if os(OSX)
            let bundleIdentifier: String? = Bundle.main.bundleIdentifier
            let temp: String = bundleIdentifier == nil ? NSTemporaryDirectory() : NSTemporaryDirectory() +
                bundleIdentifier! + "/"
        #else
            let temp: String = NSTemporaryDirectory()
        #endif

        if !fileManager.fileExists(atPath: temp) {
            do {
                try fileManager.createDirectory(
                    atPath: temp,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
            } catch {
                logger.warn(error)
            }
        }

        let filename: String = Int(timestamp.seconds).description + ".ts"
        let url = URL(fileURLWithPath: temp + filename)

        if let currentFileURL: URL = currentFileURL {
            files.append(M3UMediaInfo(url: currentFileURL, duration: duration))
            sequence += 1
        }

        fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
        if TSFileWriter.defaultSegmentMaxCount <= files.count {
            let info: M3UMediaInfo = files.removeFirst()
            do {
                try fileManager.removeItem(at: info.url as URL)
            } catch {
                logger.warn(error)
            }
        }
        currentFileURL = url
        audioContinuityCounter = 0
        videoContinuityCounter = 0

        nstry({
            self.currentFileHandle?.synchronizeFile()
        }, { exeption in
            logger.warn("\(exeption)")
        })

        currentFileHandle?.closeFile()
        currentFileHandle = try? FileHandle(forWritingTo: url)

        writeProgram()
        rotatedTimestamp = timestamp
    }

    override func write(_ data: Data) {
        nstry({
            self.currentFileHandle?.write(data)
        }, { exception in
            self.currentFileHandle?.write(data)
            logger.warn("\(exception)")
        })
        super.write(data)
    }

    override func stopRunning() {
        guard !isRunning.value else {
            return
        }
        currentFileURL = nil
        currentFileHandle = nil
        removeFiles()
        super.stopRunning()
    }

    func getFilePath(_ fileName: String) -> String? {
        files.first { $0.url.absoluteString.contains(fileName) }?.url.path
    }

    private func removeFiles() {
        let fileManager = FileManager.default
        for info in files {
            do {
                try fileManager.removeItem(at: info.url as URL)
            } catch {
                logger.warn(error)
            }
        }
        files.removeAll()
    }
}
