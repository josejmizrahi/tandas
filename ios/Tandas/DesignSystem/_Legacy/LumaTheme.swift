import SwiftUI

// MARK: - Typography tokens

extension Brand {
    enum Typography {
        // Headlines
        static let pageTitle    = Font.system(size: 28, weight: .bold)         // "Grupos"
        static let sectionTitle = Font.system(size: 22, weight: .bold)         // "Tus grupos"
        static let heroTitle    = Font.system(size: 32, weight: .bold)         // detail page hero

        // List rows
        static let rowTitle     = Font.system(size: 17, weight: .semibold)     // group name
        static let rowMeta      = Font.system(size: 13, weight: .regular)      // group meta
        static let rowKicker    = Font.system(size: 11, weight: .semibold)     // type label uppercase

        // Body
        static let bodyLarge    = Font.system(size: 17, weight: .regular)
        static let body         = Font.system(size: 15, weight: .regular)
        static let bodyEmphasis = Font.system(size: 15, weight: .semibold)
        static let caption      = Font.system(size: 13, weight: .regular)
        static let captionEmph  = Font.system(size: 13, weight: .semibold)
        static let micro        = Font.system(size: 11, weight: .medium)

        // UI
        static let button       = Font.system(size: 15, weight: .semibold)
        static let buttonLarge  = Font.system(size: 17, weight: .semibold)
        static let inputText    = Font.system(size: 17, weight: .regular)
        static let label        = Font.system(size: 13, weight: .semibold)     // field label
        static let inlineBrand  = Font.system(size: 22, weight: .bold)         // "ruul" wordmark

        // Brand kicker (uppercase tracked)
        static let brandKicker  = Font.system(size: 13, weight: .semibold)
    }
}

// MARK: - Layout tokens (consistent paddings + sizes across pages)

extension Brand {
    enum Layout {
        // Page-level padding (Luma uses 16px horizontal everywhere).
        static let pagePadH: CGFloat        = 16
        static let pageTopPad: CGFloat      = 8       // below status bar
        static let pageBottomPad: CGFloat   = 96      // clears floating tab bar

        // Section spacing
        static let sectionGap: CGFloat      = 24      // between sections
        static let sectionInternal: CGFloat = 12      // inside a section

        // Card / row metrics
        static let rowVPad: CGFloat         = 8       // vertical padding per row
        static let rowSpacing: CGFloat      = 12      // between row image and content
        static let cardCoverSize: CGFloat   = 60      // 60x60 list image
        static let cardCoverRadius: CGFloat = 10
        static let cardSmallSize: CGFloat   = 44      // small icon avatar
        static let cardSmallRadius: CGFloat = 10

        // Buttons
        static let primaryHeight: CGFloat   = 50
        static let secondaryHeight: CGFloat = 44
        static let pillHPad: CGFloat        = 18
        static let pillVPad: CGFloat        = 12

        // Header
        static let headerAvatarSize: CGFloat = 32
        static let headerActionSize: CGFloat = 36
    }
}

// MARK: - Reusable modifiers

extension View {
    /// Standard Luma page chrome: canvas background + ignoresSafeArea.
    func lumaPage() -> some View {
        background(Brand.Surface.canvas.ignoresSafeArea())
    }

    /// Page-level horizontal padding (Luma 16pt).
    func lumaHPad() -> some View {
        padding(.horizontal, Brand.Layout.pagePadH)
    }

    /// Section header style: bold title + chevron, all aligned left.
    func lumaSectionHeader() -> some View {
        HStack(spacing: 4) {
            self.font(Brand.Typography.sectionTitle)
                .foregroundStyle(Brand.Surface.textPrimary)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Surface.textTertiary)
            Spacer()
        }
    }

    /// Standard Luma list row divider (aligned past 60x60 cover + 12pt spacing).
    func lumaRowDivider() -> some View {
        Divider()
            .background(Brand.Surface.border)
            .padding(.leading, Brand.Layout.cardCoverSize + Brand.Layout.rowSpacing)
    }

    /// Primary CTA pill (orange Luma accent + white text).
    func lumaPrimaryPill() -> some View {
        self
            .font(Brand.Typography.button)
            .foregroundStyle(.white)
            .padding(.horizontal, Brand.Layout.pillHPad)
            .padding(.vertical, Brand.Layout.pillVPad)
            .frame(minHeight: Brand.Layout.primaryHeight)
            .background(Capsule().fill(Brand.accent))
    }

    /// Secondary pill (subtle card surface + text primary).
    func lumaSecondaryPill() -> some View {
        self
            .font(Brand.Typography.button)
            .foregroundStyle(Brand.Surface.textPrimary)
            .padding(.horizontal, Brand.Layout.pillHPad)
            .padding(.vertical, Brand.Layout.pillVPad)
            .frame(minHeight: Brand.Layout.secondaryHeight)
            .background(Capsule().fill(Brand.Surface.card))
            .overlay(Capsule().stroke(Brand.Surface.border, lineWidth: 1))
    }
}

// MARK: - Brand mark (✦ ruul)

struct LumaBrandMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.Surface.textPrimary)
            Text("ruul")
                .font(Brand.Typography.inlineBrand)
                .foregroundStyle(Brand.Surface.textPrimary)
        }
    }
}

// MARK: - Avatar (initial-driven)

struct LumaAvatar: View {
    let initial: String
    let size: CGFloat

    init(initial: String, size: CGFloat = Brand.Layout.headerAvatarSize) {
        self.initial = initial
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(Brand.Surface.cardPressed)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Brand.Surface.textPrimary)
            )
    }
}

// MARK: - Standard nav header bar (back button + title + optional trailing)

struct LumaNavBar<Trailing: View>: View {
    let title: String?
    let onBack: (() -> Void)?
    let trailing: () -> Trailing

    init(
        title: String? = nil,
        onBack: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.onBack = onBack
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                        .frame(width: Brand.Layout.headerActionSize, height: Brand.Layout.headerActionSize)
                        .background(Circle().fill(Brand.Surface.card))
                        .overlay(Circle().stroke(Brand.Surface.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            if let title {
                Text(title)
                    .font(Brand.Typography.bodyEmphasis)
                    .foregroundStyle(Brand.Surface.textPrimary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Brand.Layout.pagePadH)
        .padding(.vertical, 8)
    }
}

// MARK: - Field label + container (Luma style: clean inline, no glass)

struct LumaField<Content: View>: View {
    let label: String?
    let helper: String?
    let error: String?
    let content: Content

    init(label: String? = nil, helper: String? = nil, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.helper = helper
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(Brand.Typography.label)
                    .foregroundStyle(Brand.Surface.textSecondary)
            }
            content
                .font(Brand.Typography.inputText)
                .foregroundStyle(Brand.Surface.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                        .fill(Brand.Surface.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                        .stroke(Brand.Surface.border, lineWidth: 1)
                )
            if let error {
                Text(error)
                    .font(Brand.Typography.caption)
                    .foregroundStyle(.red)
            } else if let helper {
                Text(helper)
                    .font(Brand.Typography.caption)
                    .foregroundStyle(Brand.Surface.textTertiary)
            }
        }
    }
}
