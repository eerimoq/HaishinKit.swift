import Foundation

public struct VTSessionOption {
    let key: VTSessionOptionKey
    let value: AnyObject

    public init(key: VTSessionOptionKey, value: AnyObject) {
        self.key = key
        self.value = value
    }
}

extension VTSessionOption: Hashable {
    public static func == (lhs: VTSessionOption, rhs: VTSessionOption) -> Bool {
        return lhs.key.CFString == rhs.key.CFString
    }

    public func hash(into hasher: inout Hasher) {
        return hasher.combine(key.CFString)
    }
}
