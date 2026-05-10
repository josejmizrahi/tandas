import SwiftUI
import RuulUI
import RuulCore

/// Inline card shown ONLY when CreateEventView's coordinator
/// reports `recurrenceAvailable == true`. Lets the user opt in
/// to recurrence at first-event-creation time.
public struct RecurrenceOptionsCard: View {
    @Binding var selection: RecurrenceOption
    public let group: RuulCore.Group

    public init(selection: Binding<RecurrenceOption>, group: RuulCore.Group) {
        self._selection = selection
        self.group = group
    }

    public var body: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(spacing: RuulSpacing.sm) {
                    RuulIconBadge("arrow.triangle.2.circlepath", size: .small)
                    Text("¿Crear los siguientes automáticamente?")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                if let contextLine = contextDescription {
                    Text(contextLine)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                RuulPicker(
                    selection: $selection,
                    options: RecurrenceOption.allCases.map { .init(value: $0, label: $0.displayName) }
                )
            }
        }
    }

    private var contextDescription: String? {
        // Group-level recurrence/scheduling was dropped at BigBang. Phase 2
        // ResourceSeries will reintroduce this with a richer description.
        nil
    }
}
