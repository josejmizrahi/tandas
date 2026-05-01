import SwiftUI

/// Luma-style home: small brand header + section headers + flat list rows.
struct GroupsListView: View {
    @Environment(AppState.self) private var app
    @State private var selected: Group?
    @State private var showCreate: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.Surface.canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        brandHeader
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        sectionHeader(title: "Tus grupos")
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)

                        ForEach(app.groups) { g in
                            GroupRow(group: g)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = g }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)

                            Divider()
                                .background(Brand.Surface.border)
                                .padding(.leading, 76)  // align with text, not image
                        }
                    }
                    .padding(.bottom, 96)
                }
                .refreshable { await app.refreshProfileAndGroups() }
            }
            .navigationDestination(item: $selected) { g in GroupSummaryView(group: g) }
            .navigationDestination(isPresented: $showCreate) { NewGroupWizard() }
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
            // Avatar tap → settings sheet (Luma pattern)
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

            // Brand mark
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
                // future: notifications
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
}

/// Luma-style row: 60x60 image left, title + meta stacked right, no border.
private struct GroupRow: View {
    let group: Group

    var body: some View {
        HStack(spacing: 12) {
            // Cover/icon — 60x60 rounded
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.Surface.card)
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: group.groupType.symbolName)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Brand.Surface.textPrimary)
                )

            VStack(alignment: .leading, spacing: 3) {
                // Top line — type label like Luma's organizer/badge
                Text(group.groupType.displayName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Surface.textSecondary)
                    .tracking(0.5)

                // Title — bold like Luma's event title
                Text(group.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.Surface.textPrimary)
                    .lineLimit(2)

                // Meta row — placeholder for now (would show next event time/location)
                HStack(spacing: 6) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 11))
                    Text(group.inviteCode)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Brand.Surface.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }
}
