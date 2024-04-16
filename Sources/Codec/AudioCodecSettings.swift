import AVFAudio
import Foundation

public struct AudioCodecSettings: Codable {
    public static let `default` = AudioCodecSettings()
    public static let maximumNumberOfChannels: UInt32 = 2

    enum Format: Codable {
        case aac
        case pcm

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
            }
        }
    }

    public var bitRate: Int
    public var outputChannelsMap: [Int: Int]
    var format: AudioCodecSettings.Format = .aac

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
