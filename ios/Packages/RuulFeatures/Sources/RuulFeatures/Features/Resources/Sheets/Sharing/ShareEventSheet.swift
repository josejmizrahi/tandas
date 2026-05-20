import SwiftUI
import RuulUI
import RuulCore

/// Shareable card for an event — QR + ShareLink + add-to-calendar.
/// Used by both host (share the event with non-members) and any attendee
/// (invite a friend to the same event).
public struct ShareEventSheet: View {
    @Binding var isPresented: Bool
    public let event: Event
    public let groupVocabulary: String
    public let hostName: String?
    public var onAddToCalendar: (() -> Void)?

    public init(isPresented: Binding<Bool>, event: Event, groupVocabulary: String, hostName: String?, onAddToCalendar: (() -> Void)?) {
        self._isPresented = isPresented
        self.event = event
        self.groupVocabulary = groupVocabulary
        self.hostName = hostName
        self.onAddToCalendar = onAddToCalendar
    }

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

    public var body: some View {
        ModalSheetTemplate(
            title: "Compartir evento",
            dismissAction: { isPresented = false },
            primaryCTA: ("Listo", { isPresented = false })
        ) {
            VStack(spacing: RuulSpacing.lg) {
                Text("Quien escanee este código va directo al evento.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)

                qrCard

                ShareLink(item: shareMessage) {
                    HStack(spacing: RuulSpacing.xs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityHidden(true)
                        Text("Compartir link")
                            .font(.subheadline)
                    }
                    .foregroundStyle(Color.ruulTextInverse)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.md)
                    .background(Color.ruulAccent, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                }
                .buttonStyle(.ruulPress)

                if let onAddToCalendar {
                    Button {
                        onAddToCalendar()
                    } label: {
                        HStack(spacing: RuulSpacing.xs) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .accessibilityHidden(true)
                            Text("Agregar a Calendario")
                                .font(.subheadline)
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.md)
                        .background(
                            Color.ruulSurface,
                            in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.ruulPress)
                }
            }
        }
    }

    private var qrCard: some View {
        VStack(spacing: RuulSpacing.sm) {
            qrImage
                .frame(width: 220, height: 220)
                .padding(RuulSpacing.md)
                .background(Color.white, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))

            VStack(spacing: 2) {
                Text(event.title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                Text(event.startsAt.ruulFullDateTime)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
    }
}
