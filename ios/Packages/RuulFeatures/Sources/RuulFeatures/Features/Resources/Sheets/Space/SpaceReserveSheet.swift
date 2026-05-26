import SwiftUI
import RuulUI
import RuulCore

/// FASE 3 C.2 surface 6: B.2 form-commit reserve flow for a space. The
/// `book_space` RPC (mig 00266) was already shipped — this sheet wires
/// it to the existing placeholder form (date + start time + duration)
/// and keeps the warmth pattern used by RecordSharedExpenseSheet /
/// CheckInAssetSheet (successPhrase + sensoryFeedback + 700ms breath).
///
/// `notes` is an optional free-text field (purpose / context). When the
/// space is at capacity the RPC raises a structured error that the
/// sheet surfaces inline; future iterations can route to `join_waitlist`
/// from the same surface.
public struct SpaceReserveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    let resourceId: UUID
    let resourceName: String
    let onSubmitted: (() -> Void)?

    @State private var date: Date = .now
    @State private var startTime: Date = .now
    @State private var durationHours: Int = 2
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var error: String?
    @State private var successPhrase: String?

    public init(
        resourceId: UUID,
        resourceName: String,
        onSubmitted: (() -> Void)? = nil
    ) {
        self.resourceId = resourceId
        self.resourceName = resourceName
        self.onSubmitted = onSubmitted
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Reservar \(resourceName)") {
                    DatePicker("Fecha", selection: $date, displayedComponents: .date)
                    DatePicker("Hora de inicio", selection: $startTime, displayedComponents: .hourAndMinute)
                    Stepper("Duración: \(durationHours) h", value: $durationHours, in: 1...12)
                }
                Section("Notas (opcional)") {
                    TextField("Para qué la usas", text: $notes, axis: .vertical)
                }
                if let successPhrase {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(successPhrase)
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Reservar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reservar") { Task { await submit() } }
                        .disabled(isSubmitting || successPhrase != nil)
                }
            }
            .sensoryFeedback(.success, trigger: successPhrase)
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let calendar = Calendar.current
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        var combined = DateComponents()
        combined.year = dateComponents.year
        combined.month = dateComponents.month
        combined.day = dateComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        guard let startsAt = calendar.date(from: combined) else {
            error = "Fecha inválida"
            return
        }
        let endsAt = startsAt.addingTimeInterval(TimeInterval(durationHours) * 3600)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await app.spaceLifecycleRepo.bookSpace(
                space: resourceId,
                startsAt: startsAt,
                endsAt: endsAt,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            successPhrase = "Reservado · \(durationHours)h"
            try? await Task.sleep(for: .milliseconds(700))
            onSubmitted?()
            dismiss()
        } catch let lifecycle as SpaceLifecycleError {
            self.error = lifecycle.errorDescription ?? "No pudimos reservar"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
