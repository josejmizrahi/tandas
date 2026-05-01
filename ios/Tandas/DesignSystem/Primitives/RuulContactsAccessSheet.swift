import SwiftUI
import ContactsUI
import Contacts

/// Wrapper around `CNContactPickerViewController` that returns contacts as
/// E.164-friendly tuples. Apply via `.ruulContactsPicker(...)` to any view.
///
/// Authorization: `Info.plist` must include
/// `NSContactsUsageDescription`. This sheet does NOT request authorization
/// proactively — the picker handles that flow internally, prompting the user
/// the first time it's shown.
public struct RuulContactsPickerSheet: UIViewControllerRepresentable {
    @Binding public var isPresented: Bool
    public let onSelected: ([RuulContactPick]) -> Void

    public init(isPresented: Binding<Bool>, onSelected: @escaping ([RuulContactPick]) -> Void) {
        self._isPresented = isPresented
        self.onSelected = onSelected
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }

    public func updateUIViewController(_: CNContactPickerViewController, context: Context) {}

    public final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: RuulContactsPickerSheet

        init(_ parent: RuulContactsPickerSheet) {
            self.parent = parent
        }

        public func contactPickerDidCancel(_: CNContactPickerViewController) {
            parent.isPresented = false
        }

        public func contactPicker(_: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            let picks: [RuulContactPick] = contacts.flatMap { contact -> [RuulContactPick] in
                let displayName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return contact.phoneNumbers.compactMap { phone in
                    let raw = phone.value.stringValue
                    let digits = raw.filter(\.isNumber)
                    guard !digits.isEmpty else { return nil }
                    return RuulContactPick(name: displayName.isEmpty ? raw : displayName, phoneRaw: raw, phoneDigits: digits)
                }
            }
            parent.onSelected(picks)
            parent.isPresented = false
        }

        public func contactPicker(_: CNContactPickerViewController, didSelect contact: CNContact) {
            self.contactPicker(CNContactPickerViewController(), didSelect: [contact])
        }
    }
}

public struct RuulContactPick: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let name: String
    public let phoneRaw: String        // as the user has it stored
    public let phoneDigits: String     // digits only, no formatting

    public init(name: String, phoneRaw: String, phoneDigits: String) {
        self.name = name
        self.phoneRaw = phoneRaw
        self.phoneDigits = phoneDigits
    }
}

public extension View {
    func ruulContactsPicker(
        isPresented: Binding<Bool>,
        onSelected: @escaping ([RuulContactPick]) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            RuulContactsPickerSheet(isPresented: isPresented, onSelected: onSelected)
                .ignoresSafeArea()
        }
    }
}

#if DEBUG
private struct RuulContactsPreview: View {
    @State var presented = false
    @State var picks: [RuulContactPick] = []

    var body: some View {
        VStack(spacing: RuulSpacing.s4) {
            RuulButton("Pick contacts") { presented = true }
            ForEach(picks) { pick in
                Text("\(pick.name) — \(pick.phoneRaw)")
                    .ruulTextStyle(RuulTypography.body)
            }
        }
        .padding(RuulSpacing.s5)
        .ruulContactsPicker(isPresented: $presented) { newPicks in
            picks = newPicks
        }
    }
}

#Preview("RuulContactsPickerSheet") {
    RuulContactsPreview()
}
#endif
