import Accelerate
import CoreVideo
import Foundation

extension CVPixelBuffer {
    enum Error: Swift.Error {
        case failedToMakevImage_Buffer(_ error: vImage_Error)
    }

    static var format = vImage_CGImageFormat(
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        colorSpace: nil,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue),
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent
    )

    var width: Int {
        CVPixelBufferGetWidth(self)
    }

    var height: Int {
        CVPixelBufferGetHeight(self)
    }

    @discardableResult
    func lockBaseAddress(_ lockFlags: CVPixelBufferLockFlags = CVPixelBufferLockFlags.readOnly) -> CVReturn {
        return CVPixelBufferLockBaseAddress(self, lockFlags)
    }

    @discardableResult
    func unlockBaseAddress(_ lockFlags: CVPixelBufferLockFlags = CVPixelBufferLockFlags
        .readOnly) -> CVReturn
    {
        return CVPixelBufferUnlockBaseAddress(self, lockFlags)
    }
}
