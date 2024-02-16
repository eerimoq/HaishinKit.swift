import AVFAudio
import Foundation

/// The AudioCodecSettings class  specifying audio compression settings.
public struct AudioCodecSettings: Codable {
    /// The default value.
    public static let `default` = AudioCodecSettings()

    /// Maximum number of channels supported by the system
    public static let maximumNumberOfChannels: UInt32 = 2

    /// The type of the AudioCodec supports format.
    enum Format: Codable {
        case aac
        case pcm
        case opus

        func makeAudioBuffer(_ format: AVAudioFormat) -> AVAudioBuffer? {
            switch self {
            case .aac:
                return AVAudioCompressedBuffer(
                    format: format,
                    packetCapacity: 1,
                    maximumPacketSize: 1024 * Int(format.channelCount)
                )
            case .pcm:
                return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)
            case .opus:
                return AVAudioCompressedBuffer(
                    format: format,
                    packetCapacity: 1,
                    maximumPacketSize: 1024 * Int(format.channelCount)
                )
            }
        }

        func makeAudioFormat(_ inSourceFormat: AudioStreamBasicDescription?) -> AVAudioFormat? {
            guard let inSourceFormat else {
                return nil
            }
            switch self {
            case .aac:
                var streamDescription = AudioStreamBasicDescription(
                    mSampleRate: inSourceFormat.mSampleRate,
                    mFormatID: kAudioFormatMPEG4AAC,
                    mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                    mBytesPerPacket: 0,
                    mFramesPerPacket: 1024,
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: min(
                        inSourceFormat.mChannelsPerFrame,
                        AudioCodecSettings.maximumNumberOfChannels
                    ),
                    mBitsPerChannel: 0,
                    mReserved: 0
                )
                return AVAudioFormat(streamDescription: &streamDescription)
            case .pcm:
                return AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: inSourceFormat.mSampleRate,
                    channels: min(
                        inSourceFormat.mChannelsPerFrame,
                        AudioCodecSettings.maximumNumberOfChannels
                    ),
                    interleaved: true
                )
            case .opus:
                var streamDescription = AudioStreamBasicDescription(
                    mSampleRate: inSourceFormat.mSampleRate,
                    mFormatID: kAudioFormatOpus,
                    mFormatFlags: 0,
                    mBytesPerPacket: 0,
                    mFramesPerPacket: 1024,
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: min(
                        inSourceFormat.mChannelsPerFrame,
                        AudioCodecSettings.maximumNumberOfChannels
                    ),
                    mBitsPerChannel: 0,
                    mReserved: 0
                )
                return AVAudioFormat(streamDescription: &streamDescription)
            }
        }
    }

    /// Specifies the bitRate of audio output.
    public var bitRate: Int

    /// Map of the output to input channels
    public var outputChannelsMap: [Int: Int]

    /// Specifies the output format.
    var format: AudioCodecSettings.Format = .aac

    /// Create an new AudioCodecSettings instance.
    public init(
        bitRate: Int = 64 * 1000,
        outputChannelsMap: [Int: Int] = [0: 0, 1: 1]
    ) {
        self.bitRate = bitRate
        self.outputChannelsMap = outputChannelsMap
    }

    func apply(_ converter: AVAudioConverter?, oldValue: AudioCodecSettings?) {
        guard let converter else {
            return
        }
        if bitRate != oldValue?.bitRate {
            let minAvailableBitRate = converter.applicableEncodeBitRates?.min(by: { a, b in
                a.intValue < b.intValue
            })?.intValue ?? bitRate
            let maxAvailableBitRate = converter.applicableEncodeBitRates?.max(by: { a, b in
                a.intValue < b.intValue
            })?.intValue ?? bitRate
            converter.bitRate = min(maxAvailableBitRate, max(minAvailableBitRate, bitRate))
            logger.info("Audio bitrate: \(converter.bitRate), maximum: \(maxAvailableBitRate)")
        }
    }
}
