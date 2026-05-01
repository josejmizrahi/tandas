import SwiftUI

/// Luma-style empty: same brand header, inline empty card with copy + small symbol.
struct EmptyGroupsView: View {
    @Environment(AppState.self) private var app
    @State private var showCreate: Bool = false
    @State private var showJoin: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.Surface.canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        brandHeader
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        sectionHeader(title: "Tus grupos")
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)

                        emptyCard
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)

                        sectionHeader(title: "Empezar")
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)

                        VStack(spacing: 8) {
                            actionRow(title: "Crear un grupo",
                                      copy: "Cena recurrente, tanda, equipo…",
                                      systemImage: "plus.square") { showCreate = true }
                            actionRow(title: "Unirme con código",
                                      copy: "Pega el código de invitación.",
                                      systemImage: "ticket") { showJoin = true }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 96)
                }
            }
            .navigationDestination(isPresented: $showCreate) { NewGroupWizard() }
            .navigationDestination(isPresented: $showJoin) { JoinByCodeView() }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Button {
                showSettings = true
            } label: {
                Circle()
                    .fill(Brand.Surface.cardPressed)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(initial)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.Surface.textPrimary)
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.Surface.textPrimary)
                Text("ruul")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Brand.Surface.textPrimary)
            }

            Spacer()

            Button {
                showCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Brand.accent))
            }
            .buttonStyle(.plain)

            Button {
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Brand.Surface.textPrimary)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var initial: String {
        let name = app.profile?.displayName ?? ""
        return String(name.prefix(1)).uppercased()
    }

    private func sectionHeader(title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Brand.Surface.textPrimary)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Surface.textTertiary)
            Spacer()
        }
    }

    private var emptyCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.Surface.card)
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: "calendar")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Brand.Surface.textTertiary)
                )
            Text("No tienes grupos todavía. Crea uno o únete con un código.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func actionRow(title: String, copy: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.Surface.card)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Brand.Surface.textPrimary)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                    Text(copy)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.Surface.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.Surface.textTertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: showCreate || showJoin)
    }
}
