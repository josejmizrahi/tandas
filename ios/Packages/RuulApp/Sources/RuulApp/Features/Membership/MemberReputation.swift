import SwiftUI
import RuulCore

struct MemberReputationSnapshot: Identifiable {
    let member: ContextMember
    let score: Int
    let attendancePercent: Int?
    let hostedEvents: Int
    let completedCommitments: Int
    let openCommitments: Int
    let settledMoneyObligations: Int
    let openMoneyObligations: Int
    let openFines: Int
    let missedEvents: Int
    let lateEvents: Int
    let recentActivityCount: Int
    let moneyActivityCount: Int

    var id: UUID { member.actorId }

    var hasSignals: Bool {
        attendancePercent != nil
            || hostedEvents > 0
            || completedCommitments > 0
            || settledMoneyObligations > 0
            || openMoneyObligations > 0
            || openFines > 0
            || missedEvents > 0
            || lateEvents > 0
            || recentActivityCount > 0
    }

    var shamePoints: Int {
        openFines * 4
            + openMoneyObligations * 3
            + missedEvents * 3
            + lateEvents
            + openCommitments * 2
    }

    var tint: Color {
        if score >= 80 { return Theme.Tint.success }
        if score >= 60 { return Theme.Tint.primary }
        if score >= 40 { return Theme.Tint.warning }
        return Theme.Tint.critical
    }

    var bestSignal: String {
        if hostedEvents > 0 {
            return hostedEvents == 1 ? "Organizó 1 evento" : "Organizó \(hostedEvents) eventos"
        }
        if let attendancePercent {
            return "\(attendancePercent)% asistencia"
        }
        if completedCommitments > 0 {
            return completedCommitments == 1 ? "Cumplió 1 compromiso" : "Cumplió \(completedCommitments) compromisos"
        }
        if moneyActivityCount > 0 {
            return moneyActivityCount == 1 ? "Registró dinero 1 vez" : "Registró dinero \(moneyActivityCount) veces"
        }
        if recentActivityCount > 0 {
            return recentActivityCount == 1 ? "Participó recientemente" : "\(recentActivityCount) movimientos recientes"
        }
        return "Sin historial suficiente"
    }

    var riskSignal: String {
        if openFines > 0 {
            return openFines == 1 ? "1 multa abierta" : "\(openFines) multas abiertas"
        }
        if openMoneyObligations > 0 {
            return openMoneyObligations == 1 ? "1 deuda abierta" : "\(openMoneyObligations) deudas abiertas"
        }
        if missedEvents > 0 {
            return missedEvents == 1 ? "1 falta" : "\(missedEvents) faltas"
        }
        if lateEvents > 0 {
            return lateEvents == 1 ? "1 tardanza" : "\(lateEvents) tardanzas"
        }
        if openCommitments > 0 {
            return openCommitments == 1 ? "1 compromiso pendiente" : "\(openCommitments) compromisos pendientes"
        }
        return "Sin riesgos visibles"
    }
}

enum MemberReputationBuilder {
    static func load(
        context: AppContext,
        members: [ContextMember],
        rpc: any RuulRPCClient
    ) async -> [UUID: MemberReputationSnapshot] {
        guard !members.isEmpty, !context.isPersonal else { return [:] }
        let activeMembers = members.filter { !$0.isPlaceholder && !$0.isInvited }
        guard !activeMembers.isEmpty else { return [:] }

        do {
            async let eventsTask = rpc.listEvents(contextId: context.id)
            async let obligationsTask = rpc.listObligations(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (events, obligations, summary) = try await (eventsTask, obligationsTask, summaryTask)

            let relevantEvents = events
                .filter { !$0.isScheduled }
                .sorted { ($0.startsAt ?? .distantPast) > ($1.startsAt ?? .distantPast) }
                .prefix(40)

            let participantsByEvent = await withTaskGroup(of: (UUID, [EventParticipant]).self) { group in
                for event in relevantEvents {
                    group.addTask {
                        let participants = (try? await rpc.listEventParticipants(eventId: event.id)) ?? []
                        return (event.id, participants)
                    }
                }
                var out: [UUID: [EventParticipant]] = [:]
                for await (eventId, participants) in group {
                    out[eventId] = participants
                }
                return out
            }

            var stats = Dictionary(
                uniqueKeysWithValues: activeMembers.map { member in
                    (member.actorId, MemberReputationStats(member: member))
                }
            )

            for event in relevantEvents {
                if let hostId = event.hostActorId, stats[hostId] != nil {
                    stats[hostId]?.hostedEvents += 1
                }
                for participant in participantsByEvent[event.id, default: []] {
                    guard stats[participant.participantActorId] != nil else { continue }
                    stats[participant.participantActorId]?.rsvpEvents += participant.rsvpAt == nil ? 0 : 1
                    switch participant.status {
                    case "attended":
                        stats[participant.participantActorId]?.attendedEvents += 1
                    case "late":
                        stats[participant.participantActorId]?.attendedEvents += 1
                        stats[participant.participantActorId]?.lateEvents += 1
                    case "cancelled", "declined":
                        stats[participant.participantActorId]?.cancelledEvents += 1
                    case "no_show", "absent", "missed":
                        stats[participant.participantActorId]?.missedEvents += 1
                    default:
                        if participant.checkedIn {
                            stats[participant.participantActorId]?.attendedEvents += 1
                        }
                    }
                    if (participant.minutesLate ?? 0) > 0 {
                        stats[participant.participantActorId]?.lateEvents += 1
                    }
                }
            }

            for obligation in obligations {
                if stats[obligation.debtorActorId] != nil {
                    if obligation.isMoneyKind {
                        if obligation.isOpen {
                            stats[obligation.debtorActorId]?.openMoneyObligations += 1
                            if obligation.obligationType == "fine" {
                                stats[obligation.debtorActorId]?.openFines += 1
                            }
                        } else {
                            stats[obligation.debtorActorId]?.settledMoneyObligations += 1
                        }
                    } else if obligation.isCompleted {
                        stats[obligation.debtorActorId]?.completedCommitments += 1
                    } else if obligation.isOpen {
                        stats[obligation.debtorActorId]?.openCommitments += 1
                    }
                }
                if stats[obligation.creditorActorId] != nil, obligation.isMoneyKind, !obligation.isOpen {
                    stats[obligation.creditorActorId]?.settledMoneyObligations += 1
                }
            }

            for activity in summary.recentActivity {
                guard let actorId = activity.actorId, stats[actorId] != nil else { continue }
                stats[actorId]?.recentActivityCount += 1
                if activity.eventType.hasPrefix("expense.") || activity.eventType.hasPrefix("money.") {
                    stats[actorId]?.moneyActivityCount += 1
                }
            }

            return Dictionary(uniqueKeysWithValues: stats.values.map { snapshot in
                let result = snapshot.snapshot()
                return (result.member.actorId, result)
            })
        } catch {
            return [:]
        }
    }
}

private struct MemberReputationStats {
    let member: ContextMember
    var rsvpEvents = 0
    var attendedEvents = 0
    var cancelledEvents = 0
    var missedEvents = 0
    var lateEvents = 0
    var hostedEvents = 0
    var completedCommitments = 0
    var openCommitments = 0
    var settledMoneyObligations = 0
    var openMoneyObligations = 0
    var openFines = 0
    var recentActivityCount = 0
    var moneyActivityCount = 0

    func snapshot() -> MemberReputationSnapshot {
        let eventTotal = attendedEvents + cancelledEvents + missedEvents
        let attendancePercent = eventTotal > 0
            ? Int(((Double(attendedEvents) / Double(eventTotal)) * 100).rounded())
            : nil
        let score = boundedScore(attendancePercent: attendancePercent)
        return MemberReputationSnapshot(
            member: member,
            score: score,
            attendancePercent: attendancePercent,
            hostedEvents: hostedEvents,
            completedCommitments: completedCommitments,
            openCommitments: openCommitments,
            settledMoneyObligations: settledMoneyObligations,
            openMoneyObligations: openMoneyObligations,
            openFines: openFines,
            missedEvents: missedEvents,
            lateEvents: lateEvents,
            recentActivityCount: recentActivityCount,
            moneyActivityCount: moneyActivityCount
        )
    }

    private func boundedScore(attendancePercent: Int?) -> Int {
        var score = attendancePercent.map { 45 + Int(Double($0) * 0.35) } ?? 55
        score += min(hostedEvents * 5, 15)
        score += min(completedCommitments * 3, 12)
        score += min(settledMoneyObligations * 2, 10)
        score += min(recentActivityCount, 8)
        score += min(moneyActivityCount, 8)
        score -= min(openMoneyObligations * 7, 25)
        score -= min(openFines * 10, 30)
        score -= min(missedEvents * 12, 36)
        score -= min(lateEvents * 4, 20)
        score -= min(openCommitments * 4, 16)
        return min(100, max(0, score))
    }
}
