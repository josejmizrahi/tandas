import SwiftUI

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
        .tint(Color.ruulAccentPrimary)
        .padding(.horizontal, RuulSpacing.s4)
        .padding(.vertical, RuulSpacing.s2)
        .ruulGlass(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous),
            material: .regular
        )
    }
}

#if DEBUG
private struct RuulDatePickerPreview: View {
    @State var date = Date()
    @State var datetime = Date()

    var body: some View {
        VStack(spacing: RuulSpacing.s4) {
            RuulDatePicker("Fecha", date: $date)
            RuulDatePicker("Fecha y hora", date: $datetime, components: [.date, .hourAndMinute])
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulDatePicker") {
    RuulDatePickerPreview()
}
#endif
