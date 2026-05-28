import SwiftUI
import RuulCore

/// Detail surface for a single `MoneyMovement` ledger row. Read-only:
/// Foundation iOS never mutates ledger entries (reversals require a
/// dedicated future flow). Sections: summary hero + parties (from/to/
/// paid_by/recorded_by) + meta (source / split / description / dates).
struct MoneyMovementDetailView: View {
    let movement: MoneyMovement
    let myMembershipId: UUID

    var body: some View {
        List {
            heroSection
            partiesSection
            metaSection
        }
        .navigationTitle(L10n.MoneyMovementDetail.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: movement.type.systemImageName)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 76, height: 76)
                    .background(.thinMaterial, in: Circle())

                VStack(spacing: 4) {
                    Text("\(movement.amount.formatted()) \(movement.unit)")
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                        .strikethrough(movement.isReversal)
                    Text(movement.type.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if movement.isReversal {
                    Text(L10n.MoneyMovementDetail.reversalNotice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var partiesSection: some View {
        let hasParties = movement.fromDisplayName != nil
            || movement.toDisplayName != nil
            || movement.paidByDisplayName != nil
            || movement.recordedByDisplayName != nil
        if hasParties {
            Section(L10n.MoneyMovementDetail.partiesSection) {
                if let from = movement.fromDisplayName {
                    party(label: L10n.MoneyMovementDetail.fromLabel,
                          name: from,
                          isMe: movement.fromMembershipId == myMembershipId)
                }
                if let to = movement.toDisplayName {
                    party(label: L10n.MoneyMovementDetail.toLabel,
                          name: to,
                          isMe: movement.toMembershipId == myMembershipId)
                }
                if let paidBy = movement.paidByDisplayName, paidBy != movement.fromDisplayName {
                    party(label: L10n.MoneyMovementDetail.paidByLabel,
                          name: paidBy,
                          isMe: movement.paidByMembershipId == myMembershipId)
                }
                if let recordedBy = movement.recordedByDisplayName {
                    party(label: L10n.MoneyMovementDetail.recordedByLabel,
                          name: recordedBy,
                          isMe: false)
                }
            }
        }
    }

    @ViewBuilder
    private func party(label: LocalizedStringResource, name: String, isMe: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                Text(name)
                if isMe {
                    Text("(tú)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(label)
        }
    }

    @ViewBuilder
    private var metaSection: some View {
        Section(L10n.MoneyMovementDetail.metaSection) {
            if let description = movement.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                LabeledContent {
                    Text(description)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(6)
                } label: {
                    Text(L10n.MoneyMovementDetail.descriptionLabel)
                }
            }
            if let source = movement.sourceEntityKind {
                LabeledContent {
                    Text(source.capitalized)
                } label: {
                    Text(L10n.MoneyMovementDetail.sourceLabel)
                }
            }
            if let split = movement.splitMode {
                LabeledContent {
                    Text(split.capitalized)
                } label: {
                    Text(L10n.MoneyMovementDetail.splitModeLabel)
                }
            }
            if movement.inKind {
                LabeledContent {
                    Text(L10n.MoneyMovementDetail.inKindLabel)
                } label: {
                    Text(L10n.MoneyMovementDetail.typeLabel)
                }
            }
            if let occurred = movement.occurredAt {
                LabeledContent {
                    Text(occurred, format: .dateTime.day().month().year().hour().minute())
                } label: {
                    Text(L10n.MoneyMovementDetail.occurredAtLabel)
                }
            }
            if let created = movement.createdAt, created != movement.occurredAt {
                LabeledContent {
                    Text(created, format: .dateTime.day().month().year().hour().minute())
                } label: {
                    Text(L10n.MoneyMovementDetail.recordedAtLabel)
                }
            }
        }
    }
}
