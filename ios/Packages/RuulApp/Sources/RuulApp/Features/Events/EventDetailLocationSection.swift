import SwiftUI
import RuulCore

// MARK: - F.EVENT.11 Ubicación (Section dedicada — tap → Apple Maps)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

struct EventDetailLocationSection: View {
    let event: CalendarEvent

    var body: some View {
        if !event.isVirtual,
           let location = event.locationText,
           !location.isEmpty {
            Section {
                Button {
                    openLocationInMaps(location)
                } label: {
                    Label {
                        HStack {
                            Text(location)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
            } header: {
                Text("Ubicación")
            }
        }
    }

    private func openLocationInMaps(_ location: String) {
        let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}
