import SwiftUI
import RuulCore
import RuulUI

/// Slim one-row prompt for a capability that's enabled but has no data.
/// Renders inline in the same vertical scroll instead of as a full block.
struct EmptyPromptLayout: View {
    let prompt: String

    var body: some View {
        Text(prompt)
            .ruulTextStyle(RuulTypography.subhead)
            .foregroundStyle(Color.ruulTextSecondary)
    }
}
