import Foundation
import VideoToolbox

public struct VTSessionOptionKey {
    public static let depth = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_Depth)
    public static let profileLevel = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_ProfileLevel)
    public static let H264EntropyMode =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_H264EntropyMode)
    public static let numberOfPendingFrames =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_NumberOfPendingFrames)
    public static let pixelBufferPoolIsShared =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_PixelBufferPoolIsShared)
    public static let videoEncoderPixelBufferAttributes =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_VideoEncoderPixelBufferAttributes)
    public static let aspectRatio16x9 =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_AspectRatio16x9)
    public static let cleanAperture = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_CleanAperture)
    public static let fieldCount = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_FieldCount)
    public static let fieldDetail = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_FieldDetail)
    public static let pixelAspectRatio =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_PixelAspectRatio)
    public static let progressiveScan =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_ProgressiveScan)
    public static let colorPrimaries = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_ColorPrimaries)
    public static let transferFunction =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_TransferFunction)
    public static let YCbCrMatrix = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_YCbCrMatrix)
    public static let ICCProfile = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_ICCProfile)
    public static let expectedDuration =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_ExpectedDuration)
    public static let expectedFrameRate =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_ExpectedFrameRate)
    public static let sourceFrameCount =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_SourceFrameCount)
    public static let allowFrameReordering =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_AllowFrameReordering)
    public static let allowTemporalCompression =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_AllowTemporalCompression)
    public static let maxKeyFrameInterval =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_MaxKeyFrameInterval)
    public static let maxKeyFrameIntervalDuration =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration)
    public static let multiPassStorage =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_MultiPassStorage)
    public static let forceKeyFrame = VTSessionOptionKey(CFString: kVTEncodeFrameOptionKey_ForceKeyFrame)
    public static let pixelTransferProperties =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_PixelTransferProperties)
    public static let averageBitRate = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_AverageBitRate)
    public static let dataRateLimits = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_DataRateLimits)
    public static let moreFramesAfterEnd =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_MoreFramesAfterEnd)
    public static let moreFramesBeforeStart =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_MoreFramesBeforeStart)
    public static let quality = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_Quality)
    public static let realTime = VTSessionOptionKey(CFString: kVTCompressionPropertyKey_RealTime)
    public static let maxH264SliceBytes =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_MaxH264SliceBytes)
    public static let maxFrameDelayCount =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_MaxFrameDelayCount)
    public static let encoderID = VTSessionOptionKey(CFString: kVTVideoEncoderSpecification_EncoderID)
    @available(iOS 16.0, tvOS 16.0, macOS 13.0, *)
    public static let constantBitRate =
        VTSessionOptionKey(CFString: kVTCompressionPropertyKey_ConstantBitRate)

    let CFString: CFString
}
