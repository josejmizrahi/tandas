import SwiftUI

/// Shareable card for an event — QR + ShareLink + add-to-calendar.
/// Used by both host (share the event with non-members) and any attendee
/// (invite a friend to the same event).
struct ShareEventSheet: View {
    @Binding var isPresented: Bool
    let event: Event
    let groupVocabulary: String
    let hostName: String?
    var onAddToCalendar: (() -> Void)?

    private var deepLinkURL: URL {
        InviteLinkGenerator.universal(code: event.id.uuidString)
    }

    private var shareMessage: String {
        let date = event.startsAt.ruulFullDateTime
        let location = event.locationName.map { " · \($0)" } ?? ""
        return """
        Te invito a \(event.title) en ruul.
        \(date)\(location)

        Únete: \(deepLinkURL.absoluteString)
        """
    }

    var body: some View {
        ModalSheetTemplate(
            title: "Compartir evento",
            dismissAction: { isPresented = false },
            primaryCTA: ("Listo", { isPresented = false })
        ) {
            VStack(spacing: RuulSpacing.s5) {
                Text("Quien escanee este código va directo al evento.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)

                qrCard

                ShareLink(item: shareMessage) {
                    HStack(spacing: RuulSpacing.s2) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Compartir link")
                            .ruulTextStyle(RuulTypography.body)
                    }
                    .foregroundStyle(Color.ruulTextInverse)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.s4)
                    .background(Color.ruulAccentPrimary, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
                }
                .buttonStyle(.ruulPress)

                if let onAddToCalendar {
                    Button {
                        onAddToCalendar()
                    } label: {
                        HStack(spacing: RuulSpacing.s2) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Agregar a Calendario")
                                .ruulTextStyle(RuulTypography.body)
                        }
                        .foregroundStyle(Color.ruulTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.s4)
                        .background(
                            Color.ruulBackgroundElevated,
                            in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.ruulPress)
                }
            }
        }
    }

    private var qrCard: some View {
        VStack(spacing: RuulSpacing.s3) {
            qrImage
                .frame(width: 220, height: 220)
                .padding(RuulSpacing.s4)
                .background(Color.ruulOnImage, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))

            VStack(spacing: 2) {
                Text(event.title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.center)
                Text(event.startsAt.ruulFullDateTime)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var qrImage: some View {
        if let img = QRCodeGenerator.generate(deepLinkURL.absoluteString, pointSize: 220) {
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
