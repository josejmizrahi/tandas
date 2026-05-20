import SwiftUI

/// Thin wrapper that mounts Apple-native sheet chrome inside a host
/// `.sheet(...)`. Provides:
///
///   - `NavigationStack` + native inline `.navigationTitle(title)`
///   - `Button("Cancelar")` in `.cancellationAction` placement
///   - Optional `primaryCTA` rendered in `.confirmationAction`
///   - Scrollable content area
///
/// Doctrine: doctrine §0.1 + Component Map §6 say modal sheets use
/// native nav-bar chrome (Cancelar / Listo / Save), not custom title
/// + xmark headers. This wrapper enforces that across the app while
/// keeping the 22 caller sites declarative.
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.md) {
                    content()
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.lg)
            }
            .navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let dismissAction {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar", action: dismissAction)
                    }
                }
                if let primaryCTA {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(primaryCTA.label, action: primaryCTA.perform)
                    }
                }
            }
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
