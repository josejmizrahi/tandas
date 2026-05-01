import SwiftUI

struct GlassCapsuleButton: View {
    let title: String
    let systemImage: String?
    let tint: Color
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, tint: Color = Brand.accent, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: {
            // Increment the trigger so `sensoryFeedback(_:trigger:)` actually fires
            // each time the button is tapped. Plan had `triggerKey` declared but
            // never mutated — that's a no-op for sensoryFeedback. Fix bumps it on tap.
            triggerKey &+= 1
            action()
        }) {
            HStack(spacing: Brand.Spacing.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.tandaTitle)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Brand.Spacing.xl)
            .padding(.vertical, Brand.Spacing.m + 2)
            .frame(maxWidth: .infinity)
            .adaptiveGlass(Capsule(), tint: tint, interactive: true)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: triggerKey)
    }

    @State private var triggerKey: Int = 0
}
