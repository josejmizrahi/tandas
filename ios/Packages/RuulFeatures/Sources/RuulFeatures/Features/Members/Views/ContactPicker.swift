import SwiftUI
import ContactsUI
import Contacts

/// SwiftUI wrapper around `CNContactPickerViewController` — Apple's native
/// contacts picker. Use this instead of building a custom picker:
///
///   - Native Apple UI (search, sections, accessibility, RTL all free)
///   - Apple manages the permission grant prompt automatically — the
///     picker requests access on first present and gates the listing
///   - Respects Limited Contacts (iOS 18+): if the user only shared a
///     subset, the picker shows only that subset + an inline option to
///     share more
///   - Single source of UX truth — matches Messages / Mail behavior
///
/// We use the `predicateForSelectionOfProperty` mode (vs the default
/// `didSelect contact` mode) because it guarantees the user explicitly
/// picks ONE phone number when a contact has multiple. Zero ambiguity,
/// no follow-up disambiguation sheet.
///
/// `predicateForEnablingContact` greys out contacts without any phone
/// number — we can't make a placeholder out of them anyway.
///
/// Privacy: `NSContactsUsageDescription` MUST be present in Info.plist
/// (it is, in Tandas/Resources/Info.plist).
public struct PlaceholderContactPicker: UIViewControllerRepresentable {
    /// Called when the user picks one phone for one contact. Both args
    /// are guaranteed non-nil; phone is the specific number the user
    /// tapped from the contact's card.
    public let onSelection: (CNContact, CNPhoneNumber) -> Void

    /// Called when the user dismisses the picker without picking anything.
    /// SwiftUI will dismiss the sheet automatically; this is for any
    /// cleanup the caller wants to run.
    public let onCancel: () -> Void

    public init(
        onSelection: @escaping (CNContact, CNPhoneNumber) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    public func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Only enable contacts that have at least one phone number — there's
        // nothing useful we can do with an email-only contact in this flow.
        picker.predicateForEnablingContact = NSPredicate(
            format: "phoneNumbers.@count > 0"
        )
        // Force property-level selection (the contact's card opens and the
        // user taps a specific phone). Removes the "which number?" guess.
        picker.predicateForSelectionOfProperty = NSPredicate(
            format: "key == 'phoneNumbers'"
        )
        // We only care about the phone — limit the displayable fields so
        // sensitive data (emails, addresses, notes) isn't surfaced in the
        // detail view. Native Apple UI; we just narrow the lens.
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        return picker
    }

    public func updateUIViewController(
        _ uiViewController: CNContactPickerViewController,
        context: Context
    ) {
        // No reactive state to push down.
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: PlaceholderContactPicker
        init(parent: PlaceholderContactPicker) { self.parent = parent }

        public func contactPicker(
            _ picker: CNContactPickerViewController,
            didSelect contactProperty: CNContactProperty
        ) {
            guard let phone = contactProperty.value as? CNPhoneNumber else {
                parent.onCancel()
                return
            }
            parent.onSelection(contactProperty.contact, phone)
        }

        public func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}

// MARK: - Helpers

public enum ContactPickerExtraction {
    /// Best-effort display name. CNContact's `formatted` style returns
    /// "Given Family"; falls back to a single name component if either is
    /// missing.
    public static func displayName(for contact: CNContact) -> String {
        if let formatted = CNContactFormatter.string(from: contact, style: .fullName),
           !formatted.isEmpty {
            return formatted
        }
        let given = contact.givenName.trimmingCharacters(in: .whitespaces)
        let family = contact.familyName.trimmingCharacters(in: .whitespaces)
        let joined = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        if !joined.isEmpty { return joined }
        return contact.organizationName.trimmingCharacters(in: .whitespaces)
    }
}
