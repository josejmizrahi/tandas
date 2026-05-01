import SwiftUI

/// Layout for content presented inside a modal sheet (already wrapped via
/// `.ruulSheet(...)` by the caller). Provides drag indicator + title +
/// scrollable content area + optional sticky bottom action row.
public struct ModalSheetTemplate<Content: View>: View {
    private let title: String?
    private let dismissAction: (() -> Void)?
    private let primaryCTA: (label: String, perform: () -> Void)?
    private let content: () -> Content

    public init(
        title: String? = nil,
        dismissAction: (() -> Void)? = nil,
        primaryCTA: (label: String, perform: () -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.dismissAction = dismissAction
        self.primaryCTA = primaryCTA
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                    content()
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.bottom, RuulSpacing.s5)
            }
            if let primaryCTA {
                RuulButton(primaryCTA.label, style: .primary, size: .large, fillsWidth: true) { primaryCTA.perform() }
                    .padding(.horizontal, RuulSpacing.s5)
                    .padding(.bottom, RuulSpacing.s4)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if title != nil || dismissAction != nil {
            HStack {
                if let title {
                    Text(title)
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Spacer()
                if let dismissAction {
                    Button(action: dismissAction) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.top, RuulSpacing.s4)
            .padding(.bottom, RuulSpacing.s3)
        }
    }
}

#if DEBUG
private struct ModalSheetTemplatePreview: View {
    @State var presented = true

    var body: some View {
        ZStack { Color.ruulBackgroundCanvas.ignoresSafeArea() }
            .ruulSheet(isPresented: $presented) {
                ModalSheetTemplate(
                    title: "Nueva regla",
                    dismissAction: { presented = false },
                    primaryCTA: ("Guardar", { })
                ) {
                    RuulTextField("Nombre de la regla", text: .constant(""), label: "Nombre")
                    RuulTextField("$50", text: .constant(""), label: "Multa", style: .numeric)
                    RuulTextField("Descripción", text: .constant(""), label: "Descripción", description: "Explica brevemente cuándo aplica.")
                }
            }
    }
}

#Preview("ModalSheetTemplate") {
    ModalSheetTemplatePreview()
}
#endif
