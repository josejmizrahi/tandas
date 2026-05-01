import SwiftUI

/// Full-sheet display of the user's personal check-in QR for a specific event.
/// The same QR is encoded into the Apple Wallet pass when V1.x lands.
struct MemberQRSheet: View {
    @Binding var isPresented: Bool
    let eventId: UUID
    let memberId: UUID
    let eventTitle: String

    var body: some View {
        ModalSheetTemplate(
            title: "Tu código de check-in",
            dismissAction: { isPresented = false },
            primaryCTA: ("Listo", { isPresented = false })
        ) {
            VStack(spacing: RuulSpacing.s5) {
                Text("Muestra este código al host para marcar tu llegada.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
                qrImage
                    .frame(width: 240, height: 240)
                    .padding(RuulSpacing.s4)
                    // Always-white background for QR contrast — camera scanners
                    // need pure white for reliable detection. NOT theme-adaptive.
                    .background(Color.ruulOnImage, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
                Text(eventTitle)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var qrImage: some View {
        let payload = QRSignatureService.sign(
            eventId: eventId,
            memberId: memberId,
            secret: QRSignatureService.sharedSecret
        )
        if let img = QRCodeGenerator.generate(payload, pointSize: 240) {
            img
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }
}
