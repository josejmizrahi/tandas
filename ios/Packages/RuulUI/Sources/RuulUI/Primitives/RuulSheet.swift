import SwiftUI

public extension View {
    /// Canonical Ruul modal wrappers — `.fullScreenCover` under the hood.
    /// App-wide policy 2026-05-15: every modal route is a full takeover
    /// with an explicit close affordance, not a partial-overlap sheet.
    /// These wrappers exist so call sites read "I'm presenting a modal"
    /// without mentioning the implementation detail; if the policy ever
    /// flips back to sheets, only this file changes.
    ///
    /// The legacy `ruulSheetChrome(detents:)` modifier was removed —
    /// presentation modifiers (`presentationDetents` / `presentation
    /// CornerRadius` / `presentationBackground`) only apply to `.sheet`,
    /// not to `.fullScreenCover`, so the modifier was a no-op everywhere
    /// after the policy change.
    func ruulSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        self.fullScreenCover(item: item, content: content)
    }

    func ruulSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        self.fullScreenCover(isPresented: isPresented, content: content)
    }
}

#if DEBUG
private struct RuulSheetPreview: View {
    @State var showSheet = false

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            VStack(spacing: RuulSpacing.md) {
                RuulButton("Show modal") { showSheet = true }
            }
        }
        .ruulSheet(isPresented: $showSheet) {
            VStack(spacing: RuulSpacing.md) {
                Text("Modal content")
                    .ruulTextStyle(RuulTypography.title)
                Text("Full-screen takeover. Close with an explicit affordance.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulButton("Close", style: .secondary) { showSheet = false }
                Spacer()
            }
            .padding(RuulSpacing.lg)
        }
    }
}

#Preview("RuulSheet") {
    RuulSheetPreview()
}
#endif
