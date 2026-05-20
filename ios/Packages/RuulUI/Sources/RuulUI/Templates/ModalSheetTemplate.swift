import SwiftUI

/// Layout for content presented inside a modal sheet (already wrapped via
/// `.sheet(...)` by the caller). Provides drag indicator + title +
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
                VStack(alignment: .leading, spacing: RuulSpacing.md) {
                    content()
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.lg)
            }
            if let primaryCTA {
                RuulButton(primaryCTA.label, style: .primary, size: .large, fillsWidth: true) { primaryCTA.perform() }
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.bottom, RuulSpacing.md)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if title != nil || dismissAction != nil {
            HStack {
                if let title {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                if let dismissAction {
                    Button(action: dismissAction) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.sm)
        }
    }
}

#if DEBUG
private struct ModalSheetTemplatePreview: View {
    @State var presented = true

    var body: some View {
        ZStack { Color.ruulBackground.ignoresSafeArea() }
            .sheet(isPresented: $presented) {
                ModalSheetTemplate(
                    title: "Nueva regla",
                    dismissAction: { presented = false },
                    primaryCTA: ("Guardar", { })
                ) {
                    RuulTextField("Nombre de la regla", text: .constant(""), label: "Nombre")
                    RuulTextField("$50", text: .constant(""), label: "Multa", style: .numeric)
                    RuulTextField("Descripción", text: .constant(""), label: "Descripción", description: "Explica brevemente cuándo aplica.")
                }
                .presentationDetents([.medium, .large])
            }
    }
}

#Preview("ModalSheetTemplate") {
    ModalSheetTemplatePreview()
}
#endif
