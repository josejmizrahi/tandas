import SwiftUI
import RuulUI
import RuulCore

/// Wrapper around `DatePicker` with ruul styling — compact mode by default,
/// glass effect background.
public struct RuulDatePicker: View {
    private let title: String
    @Binding private var date: Date
    private let components: DatePickerComponents
    private let range: ClosedRange<Date>?

    public init(
        _ title: String,
        date: Binding<Date>,
        components: DatePickerComponents = [.date],
        range: ClosedRange<Date>? = nil
    ) {
        self.title = title
        self._date = date
        self.components = components
        self.range = range
    }

    public var body: some View {
        SwiftUI.Group {
            if let range {
                DatePicker(title, selection: $date, in: range, displayedComponents: components)
            } else {
                DatePicker(title, selection: $date, displayedComponents: components)
            }
        }
        .datePickerStyle(.compact)
        .tint(Color.ruulAccent)
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.xs)
        .ruulGlass(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous),
            material: .regular
        )
    }
}

#if DEBUG
private struct RuulDatePickerPreview: View {
    @State var date = Date()
    @State var datetime = Date()

    var body: some View {
        VStack(spacing: RuulSpacing.md) {
            RuulDatePicker("Fecha", date: $date)
            RuulDatePicker("Fecha y hora", date: $datetime, components: [.date, .hourAndMinute])
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
    }
}

#Preview("RuulDatePicker") {
    RuulDatePickerPreview()
}
#endif
