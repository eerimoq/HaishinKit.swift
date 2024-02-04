import AVFoundation
import Foundation
import VideoToolbox

protocol VTSessionConvertible {
    func setOption(_ option: VTSessionOption) -> OSStatus
    func setOptions(_ options: [VTSessionOption]) -> OSStatus
    func encodeFrame(
        _ imageBuffer: CVImageBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        outputHandler: @escaping VTCompressionOutputHandler
    ) -> OSStatus
    func decodeFrame(_ sampleBuffer: CMSampleBuffer, outputHandler: @escaping VTDecompressionOutputHandler)
        -> OSStatus
    func invalidate()
}

extension VTSessionConvertible where Self: VTSession {
    func setOption(_ option: VTSessionOption) -> OSStatus {
        return VTSessionSetProperty(self, key: option.key.CFString, value: option.value)
    }

    func setOptions(_ options: [VTSessionOption]) -> OSStatus {
        var properties: [AnyHashable: AnyObject] = [:]
        for option in options {
            properties[option.key.CFString] = option.value
        }
        return VTSessionSetProperties(self, propertyDictionary: properties as CFDictionary)
    }
}
