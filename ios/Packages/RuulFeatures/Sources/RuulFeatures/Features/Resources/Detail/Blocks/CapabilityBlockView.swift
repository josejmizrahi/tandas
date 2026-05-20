import SwiftUI
import RuulCore
import RuulUI

/// Renders ONE CapabilityBlock by switching on its layoutKind. This is
/// the ONLY switch in the detail renderer — and it switches on layout,
/// not resource_type. Adding a new layout means adding a case here +
/// a new Layout view file.
struct CapabilityBlockView: View {
    let block: CapabilityBlock
    let tint: ResourceFamilyTint
    let onOpen: () -> Void

    var body: some View {
        if block.layoutKind == .emptyPrompt {
            // Slim prompt — no header chrome, no padding wrapper.
            Button(action: onOpen) {
                HStack(spacing: RuulSpacing.sm) {
                    Image(systemName: block.icon)
                        .foregroundStyle(Color.ruulTextSecondary)
                    EmptyPromptLayout(prompt: block.payload.emptyPrompt ?? block.title)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.vertical, RuulSpacing.md)
                .background(
                    Color.ruulSurfaceSecondary,
                    in: RoundedRectangle(cornerRadius: RuulRadius.md)
                )
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                header
                content
                if let verb = block.footerVerb {
                    Button(action: onOpen) {
                        Text(verb)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tint.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(RuulSpacing.lg)
            .background(
                Color.ruulSurfaceSecondary,
                in: RoundedRectangle(cornerRadius: RuulRadius.md)
            )
        }
    }

    private var header: some View {
        Button(action: onOpen) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: block.icon)
                    .foregroundStyle(tint.color)
                Text(block.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch block.layoutKind {
        case .summaryFacts:
            SummaryFactsLayout(facts: block.payload.facts)
        case .avatarQueue:
            AvatarQueueLayout(avatars: block.payload.avatars, tint: tint)
        case .mediaStrip:
            MediaStripLayout(media: block.payload.media)
        case .balance:
            if let b = block.payload.balance {
                BalanceLayout(fields: b, tint: tint)
            } else {
                EmptyView()
            }
        case .progress:
            if let p = block.payload.progress {
                ProgressLayout(fields: p, tint: tint)
            } else {
                EmptyView()
            }
        case .timelineMini:
            TimelineMiniLayout(entries: block.payload.timeline)
        case .emptyPrompt:
            EmptyView()   // handled in outer if-branch
        }
    }
}
