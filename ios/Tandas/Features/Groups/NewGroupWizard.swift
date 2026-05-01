import SwiftUI

struct NewGroupWizard: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int = 0
    @State private var selectedType: GroupType?
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var eventLabel: String = ""
    @State private var dayOfWeek: Int = 2
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
    @State private var location: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?
    @State private var createdGroup: Group?

    private let dayLabels = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]

    var body: some View {
        ZStack {
            Brand.Surface.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                progressBar
                    .padding(.horizontal, Brand.Layout.pagePadH)
                    .padding(.top, 8)
                    .padding(.bottom, 24)

                content
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if step > 0 { step -= 1 } else { dismiss() }
                } label: {
                    Image(systemName: step > 0 ? "chevron.left" : "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Brand.Surface.canvas, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(item: $createdGroup) { g in WelcomeView(group: g) }
    }

    private var progressBar: some View {
        let totalSteps = needsStep3 ? 3 : 2
        let progress = CGFloat(step + 1) / CGFloat(totalSteps)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Paso \(min(step + 1, totalSteps)) de \(totalSteps)")
                .font(Brand.Typography.caption)
                .foregroundStyle(Brand.Surface.textTertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.Surface.card).frame(height: 4)
                    Capsule().fill(Brand.Surface.textPrimary).frame(width: geo.size.width * progress, height: 4)
                        .animation(.spring(response: 0.4), value: progress)
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: typologyStep
        case 1: identityStep
        case 2: defaultsStep
        default: EmptyView()
        }
    }

    private var typologyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("¿Qué tipo de grupo es?")
                    .font(Brand.Typography.heroTitle)
                    .foregroundStyle(Brand.Surface.textPrimary)
                Text("Esto define los defaults del grupo.")
                    .font(Brand.Typography.body)
                    .foregroundStyle(Brand.Surface.textSecondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(GroupType.allCases) { type in
                        TypologyCard(type: type, isSelected: selectedType == type) {
                            selectedType = type
                            eventLabel = type.defaultEventLabel
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(150))
                                step = 1
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, Brand.Layout.pagePadH)
            .padding(.bottom, 32)
        }
    }

    private var identityStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Cuéntanos del grupo")
                    .font(Brand.Typography.heroTitle)
                    .foregroundStyle(Brand.Surface.textPrimary)

                LumaField(label: "Nombre del grupo") {
                    TextField(selectedType?.displayName ?? "", text: $name)
                        .textInputAutocapitalization(.sentences)
                }
                LumaField(label: "Descripción", helper: "Opcional. Máx 280 caracteres.") {
                    TextField("Sirve para que los nuevos sepan de qué va.", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                LumaField(label: "Cómo le llaman al evento", helper: "Cena, partido, sesión, ensayo…") {
                    TextField(selectedType?.defaultEventLabel ?? "Evento", text: $eventLabel)
                }

                Button {
                    if needsStep3 {
                        step = 2
                    } else {
                        Task { await submit() }
                    }
                } label: {
                    Text(needsStep3 ? "Siguiente" : "Crear grupo")
                        .frame(maxWidth: .infinity)
                        .lumaPrimaryPill()
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Brand.Layout.pagePadH)
            .padding(.bottom, 32)
        }
    }

    private var defaultsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Cuándo se juntan")
                    .font(Brand.Typography.heroTitle)
                    .foregroundStyle(Brand.Surface.textPrimary)

                LumaField(label: "Día de la semana") {
                    Picker("Día", selection: $dayOfWeek) {
                        ForEach(0..<7, id: \.self) { Text(dayLabels[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                LumaField(label: "Hora") {
                    DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }

                LumaField(label: "Lugar (opcional)") {
                    TextField("Casa de Jose, club de tenis…", text: $location)
                }

                if let error = submitError {
                    Text(error)
                        .font(Brand.Typography.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Text(isSubmitting ? "Creando…" : "Crear grupo")
                        .frame(maxWidth: .infinity)
                        .lumaPrimaryPill()
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
            .padding(.horizontal, Brand.Layout.pagePadH)
            .padding(.bottom, 32)
        }
    }

    private var needsStep3: Bool { selectedType?.hasRecurringDefaults ?? false }

    private func submit() async {
        guard let selectedType else { submitError = "Falta el tipo"; return }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let params = CreateGroupParams(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.isEmpty ? nil : description,
            eventLabel: eventLabel.isEmpty ? selectedType.defaultEventLabel : eventLabel,
            currency: "MXN",
            groupType: selectedType,
            defaultDayOfWeek: needsStep3 ? dayOfWeek : nil,
            defaultStartTime: needsStep3 ? timeFormatter.string(from: startTime) : nil,
            defaultLocation: needsStep3 ? (location.isEmpty ? nil : location) : nil
        )
        do {
            createdGroup = try await app.groupsRepo.create(params)
            await app.refreshProfileAndGroups()
        } catch GroupsError.rpcFailed(let msg) {
            submitError = "El grupo no se pudo crear: \(msg)"
        } catch {
            submitError = "Algo falló. Intenta de nuevo."
        }
    }
}
