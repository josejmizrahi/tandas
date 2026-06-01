import SwiftUI
import RuulCore

/// Wraps `book_resource` for a space. Two date pickers + reason. The
/// backend rejects invalid windows (`ends <= starts`) and overlapping
/// confirmed bookings — both surface here as `errorMessage`.
struct BookSpaceSheet: View {
    @Bindable var store: ResourcesStore

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.BookSpace.startsSection) {
                    DatePicker(
                        selection: $store.bookStartsAt,
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        Text(L10n.BookSpace.startsSection)
                    }
                }
                Section(L10n.BookSpace.endsSection) {
                    DatePicker(
                        selection: $store.bookEndsAt,
                        in: store.bookStartsAt.addingTimeInterval(60)...,
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        Text(L10n.BookSpace.endsSection)
                    }
                }
                Section(L10n.BookSpace.reasonSection) {
                    TextField(
                        String(localized: L10n.BookSpace.reasonPlaceholder),
                        text: $store.bookReason,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.BookSpace.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.BookSpace.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.BookSpace.save) }
                    }
                    .disabled(!store.canSaveBookSpace || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveBookSpace()
        if ok { dismiss() }
    }
}
