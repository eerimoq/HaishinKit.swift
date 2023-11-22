import Foundation

class TSAdaptationField {
    static let fixedSectionSize: Int = 2

    var length: UInt8 = 0
    var randomAccessIndicator = false
    var splicingPointFlag = false
    var pcr: Data?
    var spliceCountdown: UInt8 = 0
    var adaptationExtension: TSAdaptationExtensionField?
    var stuffingBytes: Data?

    init() {}

    init(data: Data) {
        self.data = data
    }

    func compute() {
        length = UInt8(truncatingIfNeeded: TSAdaptationField.fixedSectionSize)
        if let pcr {
            length += UInt8(truncatingIfNeeded: pcr.count)
        }
        if let adaptationExtension {
            length += adaptationExtension.length + 1
        }
        if let stuffingBytes {
            length += UInt8(truncatingIfNeeded: stuffingBytes.count)
        }
        length -= 1
    }

    func stuffing(_ size: Int) {
        stuffingBytes = Data(repeating: 0xFF, count: size)
        length += UInt8(size)
    }
}

extension TSAdaptationField: DataConvertible {
    var data: Data {
        get {
            var byte: UInt8 = 0
            byte |= randomAccessIndicator ? 0x40 : 0
            byte |= pcr != nil ? 0x10 : 0
            byte |= splicingPointFlag ? 0x04 : 0
            let buffer = ByteArray()
                .writeUInt8(length)
                .writeUInt8(byte)
            if let pcr {
                buffer.writeBytes(pcr)
            }
            if splicingPointFlag {
                buffer.writeUInt8(spliceCountdown)
            }
            if let stuffingBytes {
                buffer.writeBytes(stuffingBytes)
            }
            return buffer.data
        }
        set {
            let buffer = ByteArray(data: newValue)
            do {
                length = try buffer.readUInt8()
                let byte: UInt8 = try buffer.readUInt8()
                randomAccessIndicator = (byte & 0x40) == 0x40
                splicingPointFlag = (byte & 0x04) == 0x04
                if splicingPointFlag {
                    spliceCountdown = try buffer.readUInt8()
                }
                stuffingBytes = try buffer.readBytes(buffer.bytesAvailable)
            } catch {
                logger.error("\(buffer)")
            }
        }
    }
}

extension TSAdaptationField: CustomDebugStringConvertible {
    var debugDescription: String {
        Mirror(reflecting: self).debugDescription
    }
}

struct TSAdaptationExtensionField {
    var length: UInt8 = 0
    var legalTimeWindowFlag = false
    var piecewiseRateFlag = false
    var seamlessSpiceFlag = false
    var legalTimeWindowOffset: UInt16 = 0
    var piecewiseRate: UInt32 = 0
    var spliceType: UInt8 = 0
    var DTSNextAccessUnit = Data(count: 5)

    init?(data: Data) {
        self.data = data
    }
}

extension TSAdaptationExtensionField: DataConvertible {
    var data: Data {
        get {
            let buffer = ByteArray()
                .writeUInt8(length)
                .writeUInt8(
                    (legalTimeWindowFlag ? 0x80 : 0) |
                        (piecewiseRateFlag ? 0x40 : 0) |
                        (seamlessSpiceFlag ? 0x1F : 0)
                )
            if legalTimeWindowFlag {
                buffer.writeUInt16((legalTimeWindowFlag ? 0x8000 : 0) | legalTimeWindowOffset)
            }
            if piecewiseRateFlag {
                buffer.writeUInt24(piecewiseRate)
            }
            if seamlessSpiceFlag {
                buffer
                    .writeUInt8(spliceType)
                    .writeUInt8(spliceType << 4 | DTSNextAccessUnit[0])
                    .writeBytes(DTSNextAccessUnit.subdata(in: 1 ..< DTSNextAccessUnit.count))
            }
            return buffer.data
        }
        set {
            let buffer = ByteArray(data: newValue)
            do {
                var byte: UInt8 = 0
                length = try buffer.readUInt8()
                byte = try buffer.readUInt8()
                legalTimeWindowFlag = (byte & 0x80) == 0x80
                piecewiseRateFlag = (byte & 0x40) == 0x40
                seamlessSpiceFlag = (byte & 0x1F) == 0x1F
                if legalTimeWindowFlag {
                    legalTimeWindowOffset = try buffer.readUInt16()
                    legalTimeWindowFlag = (legalTimeWindowOffset & 0x8000) == 0x8000
                }
                if piecewiseRateFlag {
                    piecewiseRate = try buffer.readUInt24()
                }
                if seamlessSpiceFlag {
                    DTSNextAccessUnit = try buffer.readBytes(DTSNextAccessUnit.count)
                    spliceType = DTSNextAccessUnit[0] & 0xF0 >> 4
                    DTSNextAccessUnit[0] = DTSNextAccessUnit[0] & 0x0F
                }
            } catch {
                logger.error("\(buffer)")
            }
        }
    }
}

extension TSAdaptationExtensionField: CustomDebugStringConvertible {
    var debugDescription: String {
        Mirror(reflecting: self).debugDescription
    }
}
