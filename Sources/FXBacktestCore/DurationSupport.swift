import Foundation

extension Duration {
    var fxbtSeconds: Double {
        let components = self.components
        return Double(components.seconds) + (Double(components.attoseconds) / 1.0e18)
    }
}
