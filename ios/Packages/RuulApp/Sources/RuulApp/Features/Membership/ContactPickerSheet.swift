import SwiftUI
import ContactsUI
import Contacts

/// R.5W (2026-06-08) — wrapper SwiftUI de `CNContactPickerViewController` para
/// preseleccionar nombre/teléfono/email al agregar un placeholder person.
///
/// El usuario elige un contacto de su agenda; extraemos los primeros valores
/// disponibles (nombre completo, primer teléfono, primer email) y los pasamos
/// al callback. No persistimos nada — el flujo de Ruul es one-shot: tomamos
/// los datos, llenamos el form, el usuario confirma/edita.
///
/// Requiere `NSContactsUsageDescription` en Info.plist; la primera vez que se
/// abra el picker iOS muestra el prompt de autorización.
struct ContactPickerSheet: UIViewControllerRepresentable {
    struct ImportedContact {
        let name: String?
        let phone: String?
        let email: String?
    }

    let onPick: (ImportedContact) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Sólo mostramos campos relevantes al picker.
        picker.displayedPropertyKeys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (ImportedContact) -> Void

        init(onPick: @escaping (ImportedContact) -> Void) {
            self.onPick = onPick
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let phone = contact.phoneNumbers.first.map { $0.value.stringValue }
            let email = contact.emailAddresses.first.map { $0.value as String }
            onPick(ImportedContact(
                name: name.isEmpty ? nil : name,
                phone: phone,
                email: email
            ))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onPick(ImportedContact(name: nil, phone: nil, email: nil))
        }
    }
}
