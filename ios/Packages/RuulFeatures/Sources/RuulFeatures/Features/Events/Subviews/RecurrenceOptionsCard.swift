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
        guard let freq = group.frequencyType else { return nil }
        let dayPart: String
        if let dayOfWeek = group.frequencyConfig?.dayOfWeek {
            dayPart = "los \(dayName(for: dayOfWeek))"
        } else {
            dayPart = ""
        }
        let timePart: String
        if let h = group.frequencyConfig?.hour {
            let mm = group.frequencyConfig?.minute ?? 0
            timePart = " a las \(String(format: "%02d:%02d", h, mm))"
        } else {
            timePart = ""
        }
        return "Tu grupo se ve \(freq.displayName.lowercased()) \(dayPart)\(timePart). Podemos crear los próximos eventos automáticamente."
    }

    private func dayName(for dayOfWeek: Int) -> String {
        let names = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
        guard (0..<7).contains(dayOfWeek) else { return "" }
        return names[dayOfWeek] + "s"
    }
}
