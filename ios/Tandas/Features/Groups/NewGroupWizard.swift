import SwiftUI

struct NewGroupWizard: View {
    @Environment(AppState.self) private var app
    @State private var step: Int = 0
    @State private var selectedType: GroupType?
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var eventLabel: String = ""
    @State private var dayOfWeek: Int = 2  // martes default
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
    @State private var location: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?
    @State private var createdGroup: Group?

    private let dayLabels = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: 0) {
                progressBar
                content
            }
        }
        .toolbar { toolbar }
        .navigationDestination(item: $createdGroup) { g in WelcomeView(group: g) }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let totalSteps = needsStep3 ? 3 : 2
            let progress = CGFloat(step + 1) / CGFloat(totalSteps)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(Brand.accent).frame(width: geo.size.width * progress, height: 4)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, Brand.Spacing.xl)
        .padding(.vertical, Brand.Spacing.m)
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
            VStack(spacing: Brand.Spacing.l) {
                Text("¿Qué tipo de grupo es?")
                    .font(.tandaHero).foregroundStyle(.white)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Brand.Spacing.m) {
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
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
    }

    private var identityStep: some View {
        ScrollView {
            VStack(spacing: Brand.Spacing.l) {
                Text("Cuéntanos del grupo")
                    .font(.tandaHero).foregroundStyle(.white)
                Field(label: "Nombre del grupo") {
                    TextField(selectedType?.displayName ?? "", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .foregroundStyle(.white)
                }
                Field(label: "Descripción", description: "Opcional. Máx 280 caracteres.") {
                    TextField("Sirve para que los nuevos sepan de qué va.", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                        .foregroundStyle(.white)
                }
                Field(label: "Cómo le llaman al evento", description: "Cena, partido, sesión, ensayo…") {
                    TextField(selectedType?.defaultEventLabel ?? "Evento", text: $eventLabel)
                        .foregroundStyle(.white)
                }
                GlassCapsuleButton("Siguiente") {
                    step = needsStep3 ? 2 : -1
                    if !needsStep3 { Task { await submit() } }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
    }

    private var defaultsStep: some View {
        ScrollView {
            VStack(spacing: Brand.Spacing.l) {
                Text("Cuándo se juntan").font(.tandaHero).foregroundStyle(.white)
                Field(label: "Día de la semana") {
                    Picker("Día", selection: $dayOfWeek) {
                        ForEach(0..<7, id: \.self) { Text(dayLabels[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Field(label: "Hora") {
                    DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .colorScheme(.dark)
                }
                Field(label: "Lugar (opcional)") {
                    TextField("Casa de Jose, club de tenis, …", text: $location)
                        .foregroundStyle(.white)
                }
                if let error = submitError {
                    Text(error).font(.tandaCaption).foregroundStyle(.red)
                }
                GlassCapsuleButton(isSubmitting ? "Creando…" : "Crear grupo") {
                    Task { await submit() }
                }
                .disabled(isSubmitting)
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
    }

    private var needsStep3: Bool { selectedType?.hasRecurringDefaults ?? false }

    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if step > 0 { step -= 1 }
            } label: {
                Image(systemName: "chevron.left").foregroundStyle(.white)
            }
            .opacity(step > 0 ? 1 : 0)
        }
    }

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
