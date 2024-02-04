import Foundation
import VideoToolbox

func makeVideoCompressionSession(_ videoCodec: VideoCodec) -> (any VTSessionConvertible)? {
    var session: VTCompressionSession?
    var status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: videoCodec.settings.videoSize.width,
        height: videoCodec.settings.videoSize.height,
        codecType: videoCodec.settings.format.codecType,
        encoderSpecification: nil,
        imageBufferAttributes: videoCodec.attributes as CFDictionary?,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
    )
    guard status == noErr, let session else {
        videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToCreate(status: status))
        return nil
    }
    status = session.setOptions(videoCodec.settings.options(videoCodec))
    guard status == noErr else {
        videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToPrepare(status: status))
        return nil
    }
    status = session.prepareToEncodeFrames()
    guard status == noErr else {
        videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToPrepare(status: status))
        return nil
    }
    return session
}

func makeVideoDecompressionSession(_ videoCodec: VideoCodec) -> (any VTSessionConvertible)? {
    guard let formatDescription = videoCodec.formatDescription else {
        videoCodec.delegate?.videoCodec(
            videoCodec,
            errorOccurred: .failedToCreate(status: kVTParameterErr)
        )
        return nil
    }
    var attributes = videoCodec.attributes
    attributes?.removeValue(forKey: kCVPixelBufferWidthKey)
    attributes?.removeValue(forKey: kCVPixelBufferHeightKey)
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: formatDescription,
        decoderSpecification: nil,
        imageBufferAttributes: attributes as CFDictionary?,
        outputCallback: nil,
        decompressionSessionOut: &session
    )
    guard status == noErr else {
        videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToCreate(status: status))
        return nil
    }
    return session
}
