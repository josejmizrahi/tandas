import SwiftUI

/// Horizontal scroll cover picker. User taps to select; tapped cover scales
/// up with a glass border highlight.
public struct RuulCoverPicker: View {
    @Binding private var selectedCoverId: String?
    private let covers: [RuulCover]

    public init(selectedCoverId: Binding<String?>, covers: [RuulCover] = RuulCoverCatalog.all) {
        self._selectedCoverId = selectedCoverId
        self.covers = covers
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.s3) {
                ForEach(covers) { cover in
                    Button {
                        withAnimation(.ruulSnappy) { selectedCoverId = cover.id }
                    } label: {
                        coverCell(cover)
                    }
                    .buttonStyle(.ruulPress)
                    .ruulHaptic(.selection, trigger: selectedCoverId == cover.id)
                }
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.vertical, RuulSpacing.s2)
        }
    }

    private func coverCell(_ cover: RuulCover) -> some View {
        let isSelected = selectedCoverId == cover.id
        return RuulCoverView(cover)
            .frame(width: isSelected ? 144 : 120, height: isSelected ? 96 : 80)
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(isSelected ? Color.ruulAccentPrimary : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white, Color.ruulAccentPrimary)
                        .background(Circle().fill(Color.white).padding(2))
                        .offset(x: -8, y: 8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .ruulElevation(isSelected ? .md : .sm)
    }
}

#if DEBUG
private struct RuulCoverPickerPreview: View {
    @State var selected: String? = "sunset"

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            Text("Selected: \(selected ?? "—")")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.horizontal, RuulSpacing.s5)
            RuulCoverPicker(selectedCoverId: $selected)
            if let id = selected {
                RuulCoverView(RuulCoverCatalog.cover(named: id))
                    .frame(height: 200)
                    .padding(.horizontal, RuulSpacing.s5)
            }
            Spacer()
        }
        .padding(.top, RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulCoverPicker") {
    RuulCoverPickerPreview()
}
#endif
