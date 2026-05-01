#if DEBUG
import SwiftUI

/// Root showcase view. Browse sections via NavigationStack. Toggle scheme
/// override at top.
public struct ShowcaseRootView: View {
    @State private var override: RuulSchemeOverride = .light

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Override") {
                    Picker("Scheme", selection: $override) {
                        ForEach(RuulSchemeOverride.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    if override.requiresHighContrast {
                        Text("HC override requires Settings → Accessibility → Increase Contrast")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Section("Browse") {
                    NavigationLink("Tokens") { TokensShowcaseView().ruulSchemeOverride(override) }
                    NavigationLink("Primitives") { PrimitivesShowcaseView().ruulSchemeOverride(override) }
                    NavigationLink("Patterns") { PatternsShowcaseView().ruulSchemeOverride(override) }
                    NavigationLink("Templates") { TemplatesShowcaseView().ruulSchemeOverride(override) }
                }
            }
            .navigationTitle("ruul DS Showcase")
        }
        .ruulSchemeOverride(override)
    }
}

#Preview {
    ShowcaseRootView()
}
#endif
