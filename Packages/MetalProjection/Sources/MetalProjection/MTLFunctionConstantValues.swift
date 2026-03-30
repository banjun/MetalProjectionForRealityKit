import Metal

extension MTLFunctionConstantValues {
    static func bool(_ value: Bool, index: Int = 0) -> MTLFunctionConstantValues {
        let c = MTLFunctionConstantValues()
        var value = value
        c.setConstantValue(&value, type: .bool, index: index)
        return c
    }
}
