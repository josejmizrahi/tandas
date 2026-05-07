import SwiftUI
import MapKit

/// Glass-styled autocomplete picker backed by `LocationSearchService`.
/// Suggestions appear as a list of solid tile rows below the field.
struct LocationAutocompletePicker: View {
    @Binding var locationName: String?
    @Binding var locationLat: Double?
    @Binding var locationLng: Double?

    @State private var query: String = ""
    @State private var search = LocationSearchService()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            RuulTextField(
                "Buscar ubicación",
                text: $query,
                label: "Ubicación",
                style: .search
            )
            .focused($fieldFocused)
            .onChange(of: query) { _, newValue in
                search.query = newValue
            }
            if fieldFocused, !search.suggestions.isEmpty {
                suggestionList
            } else if let name = locationName, !name.isEmpty, !fieldFocused {
                selectedRow(name: name)
            }
        }
    }

    private var suggestionList: some View {
        VStack(spacing: RuulSpacing.xs) {
            ForEach(search.suggestions, id: \.self) { suggestion in
                Button {
                    Task { await select(suggestion) }
                } label: {
                    HStack(spacing: RuulSpacing.sm) {
                        Image(systemName: "mappin")
                            .foregroundStyle(Color.ruulAccent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                                .lineLimit(1)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .ruulTextStyle(RuulTypography.caption)
                                    .foregroundStyle(Color.ruulTextSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(RuulSpacing.sm)
                    .background(
                        Color.ruulSurface,
                        in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                            .stroke(Color.ruulSeparator, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.ruulPress)
            }
        }
    }

    private func selectedRow(name: String) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(Color.ruulPositive)
            Text(name)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Button {
                locationName = nil
                locationLat = nil
                locationLng = nil
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(RuulSpacing.sm)
        .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
    }

    private func select(_ suggestion: MKLocalSearchCompletion) async {
        if let resolved = await search.resolve(suggestion) {
            locationName = resolved.name
            locationLat = resolved.lat
            locationLng = resolved.lng
            query = resolved.name
            fieldFocused = false
        }
    }
}
