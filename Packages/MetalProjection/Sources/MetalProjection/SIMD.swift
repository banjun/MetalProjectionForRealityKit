import UIKit

extension SIMD3<Float16> {
    init?(_ color: UIColor) {
        guard let cs = color.cgColor.components, cs.count >= 3 else { return nil }
        self.init(Float16(cs[0]), Float16(cs[1]), Float16(cs[2]))
    }
}
extension SIMD3<Float> {
    init?(_ color: UIColor) {
        guard let cs = color.cgColor.components, cs.count >= 3 else { return nil }
        self.init(Float(cs[0]), Float(cs[1]), Float(cs[2]))
    }
}
extension SIMD4<Float16> {
    init?(_ color: UIColor) {
        guard let cs = color.cgColor.components, cs.count >= 4 else { return nil }
        self.init(Float16(cs[0]), Float16(cs[1]), Float16(cs[2]), Float16(cs[3]))
    }
}
