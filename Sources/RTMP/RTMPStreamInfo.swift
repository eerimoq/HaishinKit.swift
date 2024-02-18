import Foundation

private struct SendTiming {
    var timestamp: Date
    var sequence: UInt32
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
    private var latestWrittenSequence: UInt32 = 0
    private var latestAckedSequence: UInt32 = 0

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
    }

    func onWritten(sequence: UInt32) {
        let now = Date()
        stats.mutate { stats in
            latestWrittenSequence = sequence
            sendTimings.append(SendTiming(timestamp: now, sequence: sequence))
            stats.packetsInFlight = (latestWrittenSequence - latestAckedSequence) / 1400
        }
    }

    func onAck(sequence: UInt32) {
        let now = Date()
        stats.mutate { stats in
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
                print("xxx ack \(sequence)")
                stats.rttMs = now.timeIntervalSince(ackedSendTiming.timestamp) * 1000
                stats.packetsInFlight = (latestWrittenSequence - latestAckedSequence) / 1400
            }
        }
    }
}
