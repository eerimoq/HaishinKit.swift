import Foundation

public struct RTMPStreamStats {
    public var rttMs: Double = 0
    public var packetsInFlight: Int = 0
}

public struct RTMPStreamInfo {
    public internal(set) var byteCount: Atomic<Int64> = .init(0)
    public internal(set) var resourceName: String?
    public internal(set) var currentBytesPerSecond: Int32 = 0
    public internal(set) var stats: Atomic<RTMPStreamStats> = .init(RTMPStreamStats())

    private var previousByteCount: Int64 = 0

    mutating func on(timer _: Timer) {
        let byteCount: Int64 = self.byteCount.value
        currentBytesPerSecond = Int32(byteCount - previousByteCount)
        previousByteCount = byteCount
    }

    mutating func clear() {
        byteCount.mutate { $0 = 0 }
        currentBytesPerSecond = 0
        previousByteCount = 0
    }
}
