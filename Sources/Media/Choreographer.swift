import Foundation
import QuartzCore

protocol ChoreographerDelegate: AnyObject {
    func choreographer(_ choreographer: any Choreographer, didFrame duration: Double)
}

protocol Choreographer {
    var isPaused: Bool { get set }
    var delegate: (any ChoreographerDelegate)? { get set }

    func startRunning()
    func stopRunning()
    func clear()
}

final class DisplayLinkChoreographer: NSObject, Choreographer {
    private static let duration = 0.0
    private static let preferredFramesPerSecond = 0

    var isPaused: Bool {
        get {
            displayLink?.isPaused ?? true
        }
        set {
            displayLink?.isPaused = newValue
        }
    }

    weak var delegate: (any ChoreographerDelegate)?
    var isRunning: Atomic<Bool> = .init(false)
    private var duration: Double = DisplayLinkChoreographer.duration
    private var displayLink: CADisplayLink? {
        didSet {
            oldValue?.invalidate()
            guard let displayLink = displayLink else {
                return
            }
            displayLink.isPaused = true
            displayLink.preferredFramesPerSecond = Self.preferredFramesPerSecond
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func clear() {
        duration = Self.duration
    }

    @objc
    private func update(displayLink: CADisplayLink) {
        delegate?.choreographer(self, didFrame: duration)
        duration += displayLink.duration
    }

    func startRunning() {
        displayLink = CADisplayLink(target: self, selector: #selector(update(displayLink:)))
        isRunning.mutate { $0 = true }
    }

    func stopRunning() {
        displayLink = nil
        duration = DisplayLinkChoreographer.duration
        isRunning.mutate { $0 = false }
    }
}
