import RuulUI
import RuulCore
#if DEBUG
import SwiftUI

struct PrimitivesShowcaseView: View {
    @State private var name = "Jose"
    @State private var otp = ""
    @State private var otpError = false
    @State private var sliderValue = 0.4
    @State private var selectedSegment: String = "Eventos"
    @State private var toggleOn = true
    @State private var pickedCadence: String = "weekly"
    @State private var date = Date()
    @State private var sheetPresented = false
    @State private var coverPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.md) {
                buttonsSection
                textFieldSection
                otpSection
                progressSection
                avatarSection
                chipSection
                segmentedSection
                toggleSection
                pickerSection
                datePickerSection
                iconBadgeSection
                presentationSection
                timelineSection
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground)
    }

    private var buttonsSection: some View {
        ShowcaseSection("RuulButton", subtitle: "5 styles × 3 sizes + loading + disabled") {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack {
                    RuulButton("Primary", style: .primary) {}
                    RuulButton("Secondary", style: .secondary) {}
                    RuulButton("Glass", style: .glass) {}
                }
                HStack {
                    RuulButton("Destructive", style: .destructive) {}
                    RuulButton("Plain", style: .plain) {}
                }
                RuulButton("Loading", isLoading: true, fillsWidth: true) {}
                RuulButton("Disabled") {}.disabled(true)
            }
        }
    }

    private var textFieldSection: some View {
        ShowcaseSection("RuulTextField") {
            VStack(spacing: RuulSpacing.sm) {
                RuulTextField("Tu nombre", text: $name, label: "Nombre")
                RuulTextField("Buscar", text: .constant(""), style: .search)
                RuulTextField("Email", text: .constant("bad@"), label: "Email", style: .email, error: "Email inválido")
            }
        }
    }

    private var otpSection: some View {
        ShowcaseSection("RuulOTPInput") {
            VStack(spacing: RuulSpacing.sm) {
                RuulOTPInput(code: $otp, hasError: $otpError)
                RuulButton("Trigger error", style: .secondary, size: .small) { otpError = true }
            }
        }
    }

    private var progressSection: some View {
        ShowcaseSection("ProgressView") {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                ProgressView(value: sliderValue)
                Slider(value: $sliderValue, in: 0...1)
            }
        }
    }

    private var avatarSection: some View {
        ShowcaseSection("RuulAvatar / RuulAvatarStack") {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack {
                    RuulAvatar(name: "Jose", size: .small)
                    RuulAvatar(name: "Ana", size: .medium)
                    RuulAvatar(name: "Ben", size: .large)
                    RuulAvatar(name: "Carla", size: .hero)
                }
                let people = (1...8).map { RuulAvatarStack.Person(id: "\($0)", name: "P\($0)") }
                RuulAvatarStack(people: people, maxVisible: 5)
            }
        }
    }

    private var chipSection: some View {
        ShowcaseSection("Filter buttons (.bordered)") {
            HStack {
                Button("Selected") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Default") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {} label: {
                    Label("Sugerencia", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var segmentedSection: some View {
        ShowcaseSection("Picker(.segmented)") {
            Picker("Sección", selection: $selectedSegment) {
                Text("Eventos").tag("Eventos")
                Text("Reglas").tag("Reglas")
                Text("Multas").tag("Multas")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var toggleSection: some View {
        ShowcaseSection("Toggle") {
            VStack(spacing: RuulSpacing.xs) {
                Toggle("Notificaciones", isOn: $toggleOn)
                Toggle(isOn: .constant(false)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-RSVP")
                            .font(.subheadline)
                        Text("Confirma automáticamente.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    private var pickerSection: some View {
        ShowcaseSection("Picker(.menu)") {
            Picker("Cadencia", selection: $pickedCadence) {
                Text("Semanal").tag("weekly")
                Text("Quincenal").tag("biweekly")
                Text("Mensual").tag("monthly")
            }
            .pickerStyle(.menu)
        }
    }

    private var datePickerSection: some View {
        ShowcaseSection("DatePicker") {
            VStack(spacing: RuulSpacing.sm) {
                DatePicker("Fecha", selection: $date, displayedComponents: [.date])
                DatePicker("Fecha y hora", selection: $date, displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    private var iconBadgeSection: some View {
        ShowcaseSection("Image(systemName:) bare") {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                Image(systemName: "calendar")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                Image(systemName: "calendar")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
            }
        }
    }

    private var presentationSection: some View {
        ShowcaseSection(".sheet / .fullScreenCover") {
            VStack(spacing: RuulSpacing.xs) {
                RuulButton("Show sheet", style: .secondary) { sheetPresented = true }
                RuulButton("Show full-screen cover", style: .secondary) { coverPresented = true }
            }
            .sheet(isPresented: $sheetPresented) {
                ModalSheetTemplate(title: "Sheet", dismissAction: { sheetPresented = false }, primaryCTA: ("OK", { sheetPresented = false })) {
                    Text("Sheet content").font(.subheadline)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $coverPresented) {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    VStack {
                        Text("Full screen").font(.largeTitle.weight(.bold)).foregroundStyle(Color.primary)
                        RuulButton("Close") { coverPresented = false }
                    }
                }
            }
        }
    }

    private var timelineSection: some View {
        ShowcaseSection("RuulTimelineItem", subtitle: "vertical history rail — first / middle / last variants") {
            VStack(spacing: 0) {
                RuulTimelineItem(
                    icon: "checkmark",
                    title: "Cerraste la cena del jueves",
                    subtitle: "12 confirmados, 9 llegaron",
                    timestamp: "HOY · 22:14",
                    tone: .positive,
                    isFirst: true
                )
                RuulTimelineItem(
                    icon: "hand.raised.fill",
                    title: "María apeló su multa de $300",
                    timestamp: "HOY · 19:02",
                    tone: .warning
                )
                RuulTimelineItem(
                    icon: "person.fill.badge.plus",
                    title: "Juan se unió al grupo",
                    timestamp: "LUN · 10:12",
                    tone: .info,
                    isLast: true
                )
            }
        }
    }
}
#endif
