import Foundation

private struct SendTiming {
    var timestamp: Date
    var sequence: Int64
}

public struct RTMPStreamStats {
    public var rttMs: Double = 0
    public var packetsInFlight: UInt32 = 0
}

public class RTMPStreamInfo {
    public internal(set) var byteCount: Atomic<Int64> = .init(0)
    public internal(set) var resourceName: String?
    public internal(set) var currentBytesPerSecond: Int32 = 0
    public internal(set) var stats: Atomic<RTMPStreamStats> = .init(RTMPStreamStats())

    private var previousByteCount: Int64 = 0
    private var sendTimings: [SendTiming] = []
    private var latestWrittenSequence: Int64 = 0
    private var latestAckedSequence: UInt32 = 0
    private var latestAckedSequenceRollover: Int64 = 0

    func onTimeout() {
        let byteCount = self.byteCount.value
        currentBytesPerSecond = Int32(byteCount - previousByteCount)
        previousByteCount = byteCount
    }

    func clear() {
        byteCount.mutate { $0 = 0 }
        stats.mutate { $0 = RTMPStreamStats() }
        currentBytesPerSecond = 0
        previousByteCount = 0
        sendTimings.removeAll()
        latestWrittenSequence = 0
        latestAckedSequence = 0
        latestAckedSequenceRollover = 0
    }

    func onWritten(sequence: Int64) {
        stats.mutate { stats in
            latestWrittenSequence = sequence
            sendTimings.append(SendTiming(timestamp: Date(), sequence: sequence))
            stats.packetsInFlight = packetsInFlight()
        }
    }

    func onAck(sequence: UInt32) {
        stats.mutate { stats in
            if sequence < latestAckedSequence {
                // Twitch rolls over at Int32.max. Bug?
                if latestAckedSequence <= Int32.max {
                    latestAckedSequenceRollover += Int64(Int32.max)
                } else {
                    latestAckedSequenceRollover = Int64(UInt32.max)
                }
            }
            latestAckedSequence = sequence
            var ackedSendTiming: SendTiming?
            while let sendTiming = sendTimings.first {
                if sequence > sendTiming.sequence {
                    ackedSendTiming = sendTiming
                    sendTimings.remove(at: 0)
                } else {
                    break
                }
            }
            if let ackedSendTiming {
                stats.rttMs = Date().timeIntervalSince(ackedSendTiming.timestamp) * 1000
                stats.packetsInFlight = packetsInFlight()
            }
        }
    }

    private func packetsInFlight() -> UInt32 {
        let latestAckedSequence = latestAckedSequenceRollover + Int64(latestAckedSequence)
        return UInt32((latestWrittenSequence - latestAckedSequence) / 1400)
    }
}
