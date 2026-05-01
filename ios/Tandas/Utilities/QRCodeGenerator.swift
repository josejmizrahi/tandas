import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Generates a QR code image from a string payload. Used for member
/// check-in QR + Wallet pass QR. Uses CIFilter (no third-party).
enum QRCodeGenerator {
    /// Returns a CGImage of the QR code at the requested point size.
    /// `pointSize` is in display points (will be scaled by screen scale).
    static func generate(_ payload: String, pointSize: CGFloat = 200) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        guard let data = payload.data(using: .utf8) else { return nil }
        filter.message = data
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // Scale up — CIFilter produces a tiny image by default.
        let scale = pointSize / output.extent.width * UIScreen.main.scale
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: UIScreen.main.scale)
    }
}
