import Testing
import Foundation
@testable import RuulCore

/// Tests de decoding contra fixtures que replican byte-a-byte los shapes
/// que emiten los RPCs MVP2 (jsonb_build_object / to_jsonb / PostgREST).
@Suite("Decoding del contrato MVP2")
struct DecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.ruul.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Fechas

    @Test("timestamps de Postgres con y sin microsegundos")
    func postgresTimestamps() throws {
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30.123456+00:00") != nil)
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30+00:00") != nil)
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30.5Z") != nil)
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30Z") != nil)
        #expect(PostgresTimestamp.parse("no es fecha") == nil)
    }

    // MARK: - Identity

    @Test("ensure_person_actor")
    func ensurePersonActor() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "actor": {
            "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "actor_kind": "person",
            "actor_subtype": "person",
            "display_name": "José",
            "slug": null,
            "status": "active",
            "visibility": "private",
            "metadata": {},
            "created_by_actor_id": null,
            "created_at": "2026-06-02T20:06:31.733651+00:00",
            "updated_at": "2026-06-02T20:06:31.733651+00:00",
            "archived_at": null
          },
          "profile": {
            "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "auth_user_id": "11111111-c51c-4bf4-9960-e1c80e27aba1",
            "full_name": "José Mizrahi",
            "preferred_name": null,
            "phone": "+5215555550001",
            "email": null,
            "avatar_url": null,
            "metadata": {},
            "created_at": "2026-06-02T20:06:31.733651+00:00",
            "updated_at": "2026-06-02T20:06:31.733651+00:00"
          }
        }
        """
        let current = try decode(CurrentActor.self, json)
        #expect(current.displayName == "José")
        #expect(current.actor.actorKind == .person)
        #expect(current.profile?.phone == "+5215555550001")
    }

    // MARK: - Contexts

    @Test("context_candidates")
    func contextCandidates() throws {
        let json = """
        {
          "personal_context": {
            "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "actor_kind": "person",
            "actor_subtype": "person",
            "display_name": "José",
            "status": "active",
            "visibility": "private",
            "created_at": "2026-06-02T20:06:31.733651+00:00"
          },
          "contexts": [
            {
              "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Cena Semanal",
              "actor_kind": "collective",
              "actor_subtype": "friend_group",
              "visibility": "private",
              "membership_type": "founder",
              "member_count": 5,
              "roles": ["admin"]
            },
            {
              "context_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Familia Mizrahi",
              "actor_kind": "collective",
              "actor_subtype": "family",
              "visibility": "private",
              "membership_type": "member",
              "member_count": 3,
              "roles": []
            }
          ]
        }
        """
        let candidates = try decode(ContextCandidates.self, json)
        #expect(candidates.personalContext.displayName == "José")
        #expect(candidates.contexts.count == 2)
        #expect(candidates.contexts[0].roles == ["admin"])
        #expect(candidates.contexts[0].memberCount == 5)
        // appContexts: persona primero + 2 colectivos
        let appContexts = candidates.appContexts
        #expect(appContexts.count == 3)
        #expect(appContexts[0].isPersonal)
        #expect(appContexts[1].isAdmin)
        #expect(!appContexts[2].isAdmin)
    }

    @Test("context_summary completo")
    func contextSummary() throws {
        let json = """
        {
          "context": {
            "id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
            "actor_kind": "collective",
            "actor_subtype": "friend_group",
            "display_name": "Cena Semanal",
            "status": "active",
            "visibility": "private",
            "created_at": "2026-06-02T20:06:31.733651+00:00"
          },
          "as_of": "2026-06-03T10:00:00.123456+00:00",
          "members_count": 5,
          "resources_count": 1,
          "pending_decisions": 2,
          "open_obligations": 3,
          "members": [
            {
              "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "display_name": "José",
              "membership_type": "founder",
              "joined_at": "2026-06-02T20:06:31.733651+00:00",
              "roles": ["admin"]
            },
            {
              "actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1",
              "display_name": "David",
              "membership_type": "member",
              "joined_at": "2026-06-02T21:06:31.733651+00:00",
              "roles": ["member"]
            }
          ],
          "my_permissions": ["context.view", "money.record", "decisions.vote"],
          "resources": [
            {
              "resource_id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Fondo común",
              "resource_type": "cash_pool",
              "estimated_value": 2500.50,
              "currency": "MXN"
            }
          ],
          "upcoming_events": [
            {
              "event_id": "d8098c1a-f86e-11da-bd1a-00112444be1e",
              "title": "Cena de los jueves",
              "event_type": "dinner",
              "starts_at": "2026-06-05T01:00:00+00:00",
              "host_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "status": "scheduled"
            }
          ],
          "open_decisions": [
            {
              "decision_id": "e8098c1a-f86e-11da-bd1a-00112444be1e",
              "title": "¿Cambiamos de restaurante?",
              "decision_type": "generic",
              "payload": {},
              "created_at": "2026-06-03T09:00:00.5+00:00"
            }
          ],
          "money": {
            "open_obligations": [
              {
                "obligation_id": "f8098c1a-f86e-11da-bd1a-00112444be1e",
                "debtor_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
                "creditor_actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1",
                "obligation_type": "expense_share",
                "amount": 325,
                "currency": "MXN"
              }
            ],
            "my_balance": -325
          },
          "active_rules": [
            {
              "rule_id": "a1098c1a-f86e-11da-bd1a-00112444be1e",
              "title": "Multa por llegar tarde",
              "trigger_event_type": "event.checked_in"
            }
          ],
          "recent_activity": [
            {
              "event_type": "expense.recorded",
              "actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1",
              "payload": {"amount": 1300, "currency": "MXN"},
              "occurred_at": "2026-06-03T08:00:00.999999+00:00"
            }
          ]
        }
        """
        let summary = try decode(ContextSummary.self, json)
        #expect(summary.context.displayName == "Cena Semanal")
        #expect(summary.membersCount == 5)
        #expect(summary.members.count == 2)
        #expect(summary.members[0].isAdmin)
        #expect(summary.members[0].isFounder)
        #expect(summary.myPermissions.contains("money.record"))
        #expect(summary.can("money.record"))
        #expect(!summary.can("members.manage"))
        #expect(summary.resources[0].estimatedValue == 2500.50)
        #expect(summary.upcomingEvents[0].title == "Cena de los jueves")
        #expect(summary.openDecisions.count == 1)
        #expect(summary.money.myBalance == -325)
        #expect(summary.money.openObligations[0].amount == 325)
        #expect(summary.activeRules[0].triggerEventType == "event.checked_in")
        #expect(summary.recentActivity[0].payload?["amount"]?.numberValue == 1300)
        // Resolución de nombres
        #expect(summary.displayName(for: summary.members[1].actorId) == "David")
        #expect(summary.displayName(for: summary.context.id) == "Cena Semanal")
        #expect(summary.displayName(for: nil) == "—")
    }

    @Test("context_summary con secciones vacías")
    func contextSummaryEmpty() throws {
        let json = """
        {
          "context": {
            "id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
            "actor_kind": "person",
            "actor_subtype": "person",
            "display_name": "José",
            "status": "active",
            "visibility": "private"
          },
          "as_of": "2026-06-03T10:00:00.123456+00:00",
          "members_count": 0,
          "resources_count": 0,
          "pending_decisions": 0,
          "open_obligations": 0,
          "members": [],
          "my_permissions": [],
          "resources": [],
          "upcoming_events": [],
          "open_decisions": [],
          "money": {"open_obligations": [], "my_balance": 0},
          "active_rules": [],
          "recent_activity": []
        }
        """
        let summary = try decode(ContextSummary.self, json)
        #expect(summary.members.isEmpty)
        // Contexto personal: autoridad total aunque my_permissions venga vacío.
        #expect(summary.can("money.record"))
    }

    @Test("my_world")
    func myWorld() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "contexts": [
            {
              "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Cena Semanal",
              "actor_kind": "collective",
              "actor_subtype": "friend_group",
              "membership_type": "founder"
            }
          ],
          "resources": [
            {
              "resource_id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Casa Valle",
              "resource_type": "house",
              "reasons": ["USE", "GOVERN via Familia Mizrahi"]
            }
          ],
          "open_obligations": [
            {
              "obligation_id": "f8098c1a-f86e-11da-bd1a-00112444be1e",
              "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
              "context_name": "Cena Semanal",
              "role": "debtor",
              "obligation_type": "expense_share",
              "amount": 325,
              "currency": "MXN"
            }
          ]
        }
        """
        let world = try decode(MyWorld.self, json)
        #expect(world.contexts.count == 1)
        #expect(world.resources[0].reasons.count == 2)
        #expect(world.resources[0].reasons.contains("USE"))
        #expect(world.openObligations[0].iOwe)
    }

    // MARK: - Resources

    @Test("resource_detail con rights")
    func resourceDetail() throws {
        let json = """
        {
          "resource": {
            "id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
            "resource_type": "house",
            "display_name": "Casa Valle",
            "description": "Casa familiar",
            "status": "active",
            "estimated_value": 4500000,
            "currency": "MXN",
            "created_by_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "canonical_owner_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
            "metadata": {},
            "client_id": null,
            "created_at": "2026-06-02T20:06:31.733651+00:00",
            "updated_at": "2026-06-02T20:06:31.733651+00:00",
            "archived_at": null
          },
          "rights": [
            {
              "right_id": "11111111-f86e-11da-bd1a-00112444be1e",
              "holder_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
              "holder_display_name": "Familia Mizrahi",
              "right_kind": "OWN",
              "percent": 100,
              "scope": null,
              "starts_at": null,
              "ends_at": null
            },
            {
              "right_id": "22222222-f86e-11da-bd1a-00112444be1e",
              "holder_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "holder_display_name": "José",
              "right_kind": "USE",
              "percent": null,
              "scope": null,
              "starts_at": null,
              "ends_at": null
            }
          ]
        }
        """
        let detail = try decode(ResourceDetail.self, json)
        #expect(detail.resource.displayName == "Casa Valle")
        #expect(detail.resource.type == .house)
        #expect(detail.rights.count == 2)
        #expect(detail.rights[0].kind == .own)
        #expect(detail.rights[0].percent == 100)
        let joseId = UUID(uuidString: "0e984725-c51c-4bf4-9960-e1c80e27aba1")!
        #expect(detail.reasons(for: joseId).map(\.rightKind) == ["USE"])
    }

    @Test("list_context_resources")
    func listContextResources() throws {
        let json = """
        [
          {
            "resource_id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
            "resource_type": "house",
            "display_name": "Casa Valle",
            "status": "active",
            "estimated_value": null,
            "currency": null,
            "canonical_owner_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
            "rights": [
              {
                "right_id": "11111111-f86e-11da-bd1a-00112444be1e",
                "holder_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
                "right_kind": "OWN",
                "percent": 100
              }
            ]
          }
        ]
        """
        let resources = try decode([ContextResource].self, json)
        #expect(resources.count == 1)
        #expect(resources[0].rights.count == 1)
        #expect(resources[0].type == .house)
    }

    // MARK: - Events

    @Test("fila de calendar_events (PostgREST)")
    func calendarEventRow() throws {
        let json = """
        {
          "id": "d8098c1a-f86e-11da-bd1a-00112444be1e",
          "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
          "title": "Cena de los jueves",
          "description": null,
          "event_type": "dinner",
          "starts_at": "2026-06-05T01:00:00.482113+00:00",
          "ends_at": null,
          "timezone": "America/Mexico_City",
          "location_text": "Casa de José",
          "location_metadata": {},
          "recurrence_rule": "weekly",
          "host_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "status": "scheduled",
          "metadata": {},
          "client_id": null,
          "created_by_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "created_at": "2026-06-02T20:06:31.733651+00:00",
          "updated_at": "2026-06-02T20:06:31.733651+00:00",
          "cancelled_at": null
        }
        """
        let event = try decode(CalendarEvent.self, json)
        #expect(event.title == "Cena de los jueves")
        #expect(event.type == .dinner)
        #expect(event.isRecurring)
        #expect(event.isScheduled)
    }

    @Test("check_in_participant tarde")
    func checkInLate() throws {
        let json = """
        {
          "participant_id": "11111111-f86e-11da-bd1a-00112444be1e",
          "status": "late",
          "checked_in_at": "2026-06-05T01:31:00.482113+00:00",
          "minutes_late": 31.0,
          "rules": {"rules_matched": 1, "obligations_created": [{"obligation_id": "22222222-f86e-11da-bd1a-00112444be1e", "amount": 100}]}
        }
        """
        let result = try decode(CheckInResult.self, json)
        #expect(result.isLate)
        #expect(result.minutesLate == 31.0)
        #expect(!result.alreadyCheckedIn)
    }

    @Test("cancel_participation mismo día")
    func cancelSameDay() throws {
        let json = """
        {
          "participant_id": "11111111-f86e-11da-bd1a-00112444be1e",
          "status": "cancelled",
          "cancelled_at": "2026-06-05T00:00:00+00:00",
          "same_day_cancellation": true,
          "rules": {"rules_matched": 1}
        }
        """
        let result = try decode(CancelParticipationResult.self, json)
        #expect(result.sameDayCancellation)
    }

    @Test("close_event con rotación de host")
    func closeEvent() throws {
        let json = """
        {
          "event_id": "d8098c1a-f86e-11da-bd1a-00112444be1e",
          "status": "completed",
          "no_shows": 2,
          "next_event_id": "e8098c1a-f86e-11da-bd1a-00112444be1e",
          "next_host_actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1"
        }
        """
        let result = try decode(CloseEventResult.self, json)
        #expect(result.noShows == 2)
        #expect(result.nextEventId != nil)
        #expect(!result.alreadyClosed)
    }

    // MARK: - Money

    @Test("record_expense con obligations")
    func recordExpense() throws {
        let json = """
        {
          "transaction_id": "33333333-f86e-11da-bd1a-00112444be1e",
          "share_per_person": 325.00,
          "split_method": "equal",
          "obligations": [
            {"obligation_id": "44444444-f86e-11da-bd1a-00112444be1e", "debtor": "0e984725-c51c-4bf4-9960-e1c80e27aba1", "amount": 325.00},
            {"obligation_id": "55555555-f86e-11da-bd1a-00112444be1e", "debtor": "1e984725-c51c-4bf4-9960-e1c80e27aba1", "amount": 325.00}
          ]
        }
        """
        let result = try decode(ExpenseResult.self, json)
        #expect(result.sharePerPerson == 325)
        #expect(result.obligations.count == 2)
        #expect(!result.idempotentReplay)
    }

    @Test("generate_settlement_batch con items")
    func settlementBatch() throws {
        let json = """
        {
          "batch_id": "66666666-f86e-11da-bd1a-00112444be1e",
          "items": [
            {"from": "0e984725-c51c-4bf4-9960-e1c80e27aba1", "to": "1e984725-c51c-4bf4-9960-e1c80e27aba1", "amount": 400.00}
          ],
          "obligations_netted": 3
        }
        """
        let result = try decode(SettlementBatchResult.self, json)
        #expect(result.batchId != nil)
        #expect(result.items.count == 1)
        #expect(result.items[0].amount == 400)
        #expect(result.obligationsNetted == 3)
    }

    @Test("generate_settlement_batch cuando todo netea a cero")
    func settlementNetsToZero() throws {
        let json = """
        {
          "batch_id": null,
          "items": [],
          "message": "all obligations net to zero — settled directly",
          "obligations_settled": 2
        }
        """
        let result = try decode(SettlementBatchResult.self, json)
        #expect(result.batchId == nil)
        #expect(result.items.isEmpty)
        #expect(result.message != nil)
    }

    @Test("mark_settlement_paid")
    func markPaid() throws {
        let json = """
        {
          "item_id": "77777777-f86e-11da-bd1a-00112444be1e",
          "transaction_id": "88888888-f86e-11da-bd1a-00112444be1e",
          "batch_finalized": true,
          "obligations_closed": 3
        }
        """
        let result = try decode(MarkPaidResult.self, json)
        #expect(result.batchFinalized)
        #expect(result.obligationsClosed == 3)
        #expect(!result.alreadyPaid)
    }

    // MARK: - Decisions

    @Test("vote_decision con tally")
    func voteDecision() throws {
        let json = """
        {
          "decision_id": "e8098c1a-f86e-11da-bd1a-00112444be1e",
          "my_vote": "approve",
          "my_option": null,
          "status": "approved",
          "tally": {"approve": 3, "reject": 1, "members": 5}
        }
        """
        let result = try decode(VoteResult.self, json)
        #expect(result.status == "approved")
        #expect(result.tally?.approve == 3)
        #expect(result.tally?.members == 5)
    }

    @Test("vote_for_option result con winning_option_id (R.2Q)")
    func voteForOptionResult() throws {
        let json = """
        {
          "decision_id": "e8098c1a-f86e-11da-bd1a-00112444be1e",
          "my_vote": "approve",
          "my_option": "award_a",
          "my_option_id": "11111111-1111-1111-1111-111111111111",
          "status": "approved",
          "winning_option": "award_a",
          "winning_option_id": "11111111-1111-1111-1111-111111111111",
          "tally": {"approve": 2, "reject": 0, "members": 3,
                    "option_tally": {"award_a": 2}}
        }
        """
        let result = try decode(VoteResult.self, json)
        #expect(result.status == "approved")
        #expect(result.winningOption == "award_a")
        #expect(result.winningOptionId?.uuidString.lowercased() == "11111111-1111-1111-1111-111111111111")
        #expect(result.myOptionId != nil)
    }

    @Test("decisions row con voting_model (R.2Q)")
    func decisionWithVotingModel() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "context_actor_id": "22222222-2222-2222-2222-222222222222",
          "decision_type": "reservation_dispute",
          "title": "Disputa Casa Valle",
          "description": null,
          "status": "approved",
          "voting_model": "single_choice",
          "created_by_actor_id": "33333333-3333-3333-3333-333333333333",
          "closes_at": null,
          "decided_at": "2026-06-03T18:15:30.123456+00:00",
          "executed_at": null,
          "payload": {"conflict_id": "44444444-4444-4444-4444-444444444444"},
          "result": {
            "winning_option": "award_a",
            "winning_option_id": "55555555-5555-5555-5555-555555555555"
          },
          "created_at": "2026-06-03T18:15:30+00:00"
        }
        """
        let decision = try decode(Decision.self, json)
        #expect(decision.voting == .singleChoice)
        #expect(decision.winningOptionKey == "award_a")
        #expect(decision.winningOptionId?.uuidString.lowercased() == "55555555-5555-5555-5555-555555555555")
    }

    @Test("decision sin voting_model defaultea a yes_no_abstain")
    func decisionWithoutVotingModelDefaults() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "context_actor_id": "22222222-2222-2222-2222-222222222222",
          "decision_type": "generic",
          "title": "Sin voting_model",
          "status": "open"
        }
        """
        let decision = try decode(Decision.self, json)
        #expect(decision.voting == .yesNoAbstain)
    }

    @Test("list_decision_options (R.2Q)")
    func listDecisionOptions() throws {
        let json = """
        [
          {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "decision_id": "11111111-1111-1111-1111-111111111111",
            "option_key": "award_a",
            "title": "Asignar a David",
            "description": null,
            "payload": {
              "action": "reservation_award",
              "winner_reservation_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
              "conflict_id": "44444444-4444-4444-4444-444444444444"
            },
            "sort_order": 0,
            "status": "active",
            "created_at": "2026-06-03T18:15:30+00:00"
          },
          {
            "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "decision_id": "11111111-1111-1111-1111-111111111111",
            "option_key": "award_b",
            "title": "Asignar a Isaac",
            "description": null,
            "payload": {"action": "reservation_award"},
            "sort_order": 1,
            "status": "active",
            "created_at": null
          }
        ]
        """
        let options = try decode([DecisionOption].self, json)
        #expect(options.count == 2)
        #expect(options[0].optionKey == "award_a")
        #expect(options[0].actionKey == "reservation_award")
        #expect(options[0].sortOrder == 0)
        #expect(options[1].isActive)
    }

    @Test("decision_vote con option_id (R.2Q)")
    func decisionVoteWithOptionId() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "decision_id": "22222222-2222-2222-2222-222222222222",
          "voter_actor_id": "33333333-3333-3333-3333-333333333333",
          "vote": "approve",
          "option_id": "44444444-4444-4444-4444-444444444444",
          "voted_at": "2026-06-03T18:15:30+00:00"
        }
        """
        let vote = try decode(DecisionVote.self, json)
        #expect(vote.optionId?.uuidString.lowercased() == "44444444-4444-4444-4444-444444444444")
    }

    // MARK: - Activity

    @Test("list_activity")
    func listActivity() throws {
        let json = """
        {
          "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
          "limit": 50,
          "activity": [
            {
              "id": "99999999-f86e-11da-bd1a-00112444be1e",
              "event_type": "fine.created",
              "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "subject_type": "obligation",
              "subject_id": "44444444-f86e-11da-bd1a-00112444be1e",
              "payload": {"system": true, "amount": 100},
              "resource_id": null,
              "decision_id": null,
              "obligation_id": "44444444-f86e-11da-bd1a-00112444be1e",
              "occurred_at": "2026-06-03T08:00:00.999999+00:00"
            }
          ]
        }
        """
        let page = try decode(ActivityPage.self, json)
        #expect(page.activity.count == 1)
        #expect(page.activity[0].isSystemGenerated)
        #expect(page.activity[0].typeLabel == "Multa generada")
        #expect(page.activity[0].domain == "fine")
    }

    // MARK: - Actor capabilities (R.2S.1)

    @Test("actor_capabilities — collective con capabilities")
    func actorCapabilitiesShape() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "actor_kind": "collective",
          "actor_subtype": "friend_group",
          "capabilities": [
            "can_govern_resources",
            "can_have_members",
            "can_hold_money",
            "can_issue_decisions",
            "can_receive_contributions"
          ]
        }
        """
        let caps = try decode(ActorCapabilities.self, json)
        #expect(caps.actorKind == .collective)
        #expect(caps.actorSubtype == "friend_group")
        #expect(caps.has(.canHaveMembers))
        #expect(caps.has(.canHoldMoney))
        #expect(!caps.has(.canHaveBeneficiaries))
        #expect(!caps.has("can_have_trustees"))
    }

    @Test("actor_capabilities — array vacío decodifica como []")
    func actorCapabilitiesEmpty() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "actor_kind": "person",
          "actor_subtype": "person"
        }
        """
        let caps = try decode(ActorCapabilities.self, json)
        #expect(caps.capabilities.isEmpty)
    }

    @Test("actor_capabilities_catalog — matriz subtype + descripciones")
    func actorCapabilitiesCatalogShape() throws {
        let json = """
        {
          "capabilities": [
            {"capability_key": "can_have_members", "display_name": "Puede tener miembros", "description": "Otros actores participan"},
            {"capability_key": "can_hold_money", "display_name": "Puede tener dinero", "description": "Participa en settlement"}
          ],
          "subtypes": [
            {"actor_subtype": "trust", "capabilities": ["can_have_beneficiaries", "can_have_trustees"]},
            {"actor_subtype": "friend_group", "capabilities": ["can_have_members", "can_hold_money"]}
          ]
        }
        """
        let catalog = try decode(ActorCapabilitiesCatalog.self, json)
        #expect(catalog.capabilities.count == 2)
        #expect(catalog.subtypes.count == 2)
        #expect(catalog.capabilities(forSubtype: "friend_group") == ["can_have_members", "can_hold_money"])
        #expect(catalog.subtypes(with: .canHaveMembers) == ["friend_group"])
        #expect(catalog.displayName(for: "can_hold_money") == "Puede tener dinero")
        #expect(catalog.capabilities(forSubtype: "no_existe").isEmpty)
    }

    // MARK: - Available action canónico (R.2S-FIX)

    @Test("AvailableAction — shape canónico de 7 campos (enabled + reason + arrays)")
    func availableActionCanonical() throws {
        let json = """
        {
          "action_key": "vote",
          "label": "Votar",
          "section": "decisions",
          "enabled": true,
          "reason": "La decisión está abierta y puedes votar",
          "required_rights": [],
          "required_capabilities": []
        }
        """
        let action = try decode(AvailableAction.self, json)
        #expect(action.actionKey == "vote")
        #expect(action.label == "Votar")
        #expect(action.section == "decisions")
        #expect(action.enabled)
        #expect(action.reason == "La decisión está abierta y puedes votar")
        #expect(action.requiredRights.isEmpty)
        #expect(action.requiredCapabilities.isEmpty)
    }

    @Test("AvailableAction — defaults seguros para campos ausentes")
    func availableActionDefaults() throws {
        let json = """
        {
          "action_key": "approve",
          "label": "Aprobar",
          "section": "reservations"
        }
        """
        let action = try decode(AvailableAction.self, json)
        #expect(action.enabled)
        #expect(action.reason == nil)
        #expect(action.requiredRights.isEmpty)
        #expect(action.requiredCapabilities.isEmpty)
    }

    @Test("AvailableAction.can/enabled/inSection")
    func availableActionHelpers() {
        let actions: [AvailableAction] = [
            AvailableAction(actionKey: "vote", label: "Votar", section: "decisions", enabled: true),
            AvailableAction(actionKey: "close_decision", label: "Cerrar", section: "decisions", enabled: false, reason: "Sin permiso"),
            AvailableAction(actionKey: "pay", label: "Pagar", section: "obligations", enabled: true)
        ]
        #expect(actions.can("vote"))
        #expect(!actions.can("close_decision"))
        #expect(actions.enabled("close_decision") == nil)
        #expect(actions.inSection("decisions").count == 2)
    }

    // MARK: - DecisionDetail (R.2S)

    @Test("decision_detail con opciones + available_actions canónicos")
    func decisionDetailShape() throws {
        let json = """
        {
          "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "context_actor_id": "55555555-c51c-4bf4-9960-e1c80e27aba1",
          "decision_type": "reservation_dispute",
          "voting_model": "single_choice",
          "title": "¿Quién se queda con Casa Valle?",
          "description": null,
          "status": "open",
          "opens_at": "2026-06-03T18:15:30.123456+00:00",
          "closes_at": null,
          "decided_at": null,
          "executed_at": null,
          "payload": {},
          "result": null,
          "options": [
            {"id": "11111111-c51c-4bf4-9960-e1c80e27aba1", "option_key": "david", "title": "David", "description": null, "payload": null, "sort_order": 0, "votes": 2},
            {"id": "22222222-c51c-4bf4-9960-e1c80e27aba1", "option_key": "isaac", "title": "Isaac", "description": null, "payload": null, "sort_order": 1, "votes": 1}
          ],
          "votes_count": 3,
          "available_actions": [
            {"action_key": "vote", "label": "Votar", "section": "decisions", "enabled": true, "reason": "Puedes votar", "required_rights": [], "required_capabilities": []},
            {"action_key": "close_decision", "label": "Cerrar", "section": "decisions", "enabled": false, "reason": "Sin permiso", "required_rights": [], "required_capabilities": []}
          ],
          "created_at": "2026-06-03T18:00:00.000000+00:00"
        }
        """
        let detail = try decode(DecisionDetail.self, json)
        #expect(detail.voting == .singleChoice)
        #expect(detail.options.count == 2)
        #expect(detail.options[0].votes == 2)
        #expect(detail.votesCount == 3)
        #expect(detail.can("vote"))
        #expect(!detail.can("close_decision"))
        #expect(detail.action("close_decision") == nil)  // disabled → not "enabled"
    }

    // MARK: - ReservationDetail (R.2S)

    @Test("reservation_detail con available_actions canónicos")
    func reservationDetailShape() throws {
        let json = """
        {
          "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "resource_id": "11111111-c51c-4bf4-9960-e1c80e27aba1",
          "context_actor_id": "55555555-c51c-4bf4-9960-e1c80e27aba1",
          "requested_by_actor_id": "22222222-c51c-4bf4-9960-e1c80e27aba1",
          "reserved_for_actor_id": null,
          "starts_at": "2026-06-10T18:00:00.000000+00:00",
          "ends_at": "2026-06-12T18:00:00.000000+00:00",
          "status": "requested",
          "priority_score": null,
          "source_decision_id": null,
          "metadata": {},
          "available_actions": [
            {"action_key": "approve", "label": "Aprobar", "section": "reservations", "enabled": true, "reason": "Eres admin del recurso", "required_rights": [], "required_capabilities": []},
            {"action_key": "reject", "label": "Rechazar", "section": "reservations", "enabled": true, "reason": "Eres admin del recurso", "required_rights": [], "required_capabilities": []}
          ],
          "created_at": "2026-06-03T18:00:00.000000+00:00"
        }
        """
        let detail = try decode(ReservationDetail.self, json)
        #expect(detail.status == "requested")
        #expect(detail.can("approve"))
        #expect(detail.can("reject"))
        #expect(!detail.can("resolve_conflict"))
    }

    // MARK: - Explanation engine (R.2S.10)

    @Test("why_can_view_resource — reasons + canView")
    func whyCanViewResourceShape() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "resource_id": "11111111-c51c-4bf4-9960-e1c80e27aba1",
          "can_view": true,
          "reasons": ["Es el dueño canónico del recurso (OWN dominante)"]
        }
        """
        let why = try decode(WhyCanViewResource.self, json)
        #expect(why.canView)
        #expect(why.reasons.count == 1)
    }

    @Test("why_can_reserve — required_capability + reasons")
    func whyCanReserveShape() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "resource_id": "11111111-c51c-4bf4-9960-e1c80e27aba1",
          "can_reserve": false,
          "required_capability": "reservable",
          "reasons": [
            "El tipo \\"bank_account\\" no tiene la capability reservable",
            "Falta un derecho USE, MANAGE u OWN (o autoridad para administrar reservaciones)"
          ]
        }
        """
        let why = try decode(WhyCanReserve.self, json)
        #expect(!why.canReserve)
        #expect(why.requiredCapability == "reservable")
        #expect(why.reasons.count == 2)
    }

    @Test("why_decision_result — tally + option_tally + reasons")
    func whyDecisionResultShape() throws {
        let json = """
        {
          "decision_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "status": "approved",
          "voting_model": "yes_no_abstain",
          "tally": {"approve": 3, "reject": 1, "abstain": 0},
          "option_tally": {},
          "active_members": 5,
          "result": {"winning": "approve"},
          "reasons": [
            "Modelo de votación: yes_no_abstain",
            "Conteo: 3 a favor, 1 en contra, 0 abstención sobre 5 miembros",
            "Estado actual: approved"
          ]
        }
        """
        let why = try decode(WhyDecisionResult.self, json)
        #expect(why.tally.approve == 3)
        #expect(why.tally.reject == 1)
        #expect(why.activeMembers == 5)
        #expect(why.reasons.count == 3)
    }

    @Test("why_reservation_won — winner + reasons; sin resolver devuelve null")
    func whyReservationWonShape() throws {
        let json = """
        {
          "conflict_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "resolution_status": "resolved",
          "winner_reservation_id": "11111111-c51c-4bf4-9960-e1c80e27aba1",
          "winner_actor_id": "22222222-c51c-4bf4-9960-e1c80e27aba1",
          "recommended_winner_actor_id": "22222222-c51c-4bf4-9960-e1c80e27aba1",
          "reasons": ["Modelo de resolución: admin_override", "El motor de conflictos había recomendado a este actor"]
        }
        """
        let why = try decode(WhyReservationWon.self, json)
        #expect(why.resolutionStatus == "resolved")
        #expect(why.winnerReservationId != nil)
        #expect(why.reasons.count == 2)
    }

    @Test("why_obligation_exists — source + ruleTitle")
    func whyObligationExistsShape() throws {
        let json = """
        {
          "obligation_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "kind": "money",
          "source": "rule",
          "reason": "Multa por llegar tarde",
          "source_rule_id": "33333333-c51c-4bf4-9960-e1c80e27aba1",
          "source_decision_id": null,
          "source_event_id": "44444444-c51c-4bf4-9960-e1c80e27aba1",
          "source_reservation_id": null,
          "rule_title": "Multa por tarde",
          "metadata": {"minutes_late": 22}
        }
        """
        let why = try decode(WhyObligationExists.self, json)
        #expect(why.source == "rule")
        #expect(why.ruleTitle == "Multa por tarde")
        #expect(why.sourceRuleId != nil)
        #expect(why.sourceDecisionId == nil)
    }

    // MARK: - R.2R Obligations universales

    @Test("obligation_detail (kind action) con available_actions + completion")
    func obligationDetailActionShape() throws {
        let json = """
        {
          "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "context_actor_id": "55555555-c51c-4bf4-9960-e1c80e27aba1",
          "kind": "action",
          "obligation_type": "other",
          "status": "open",
          "title": "Traer botella de vino",
          "description": "Para la cena del viernes",
          "amount": null,
          "currency": null,
          "due_at": "2026-06-07T18:00:00.000000+00:00",
          "debtor_actor_id": "22222222-c51c-4bf4-9960-e1c80e27aba1",
          "creditor_actor_id": "55555555-c51c-4bf4-9960-e1c80e27aba1",
          "completed_at": null,
          "completed_by_actor_id": null,
          "completion_notes": null,
          "source_event_id": "44444444-c51c-4bf4-9960-e1c80e27aba1",
          "source_rule_id": null,
          "source_reservation_id": null,
          "source_decision_id": null,
          "metadata": {"created_by": "55555555-c51c-4bf4-9960-e1c80e27aba1"},
          "available_actions": [
            {"action_key": "mark_completed", "label": "Marcar como cumplida", "section": "obligations",
             "enabled": true, "reason": "Participas en esta obligación", "required_rights": [], "required_capabilities": []}
          ],
          "created_at": "2026-06-03T18:00:00.000000+00:00"
        }
        """
        let detail = try decode(ObligationDetail.self, json)
        #expect(detail.kind == "action")
        #expect(detail.title == "Traer botella de vino")
        #expect(detail.amount == nil)
        #expect(detail.can("mark_completed"))
    }

    @Test("Obligation con obligation_kind explícito + title")
    func obligationKindField() throws {
        let json = """
        {
          "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "context_actor_id": "55555555-c51c-4bf4-9960-e1c80e27aba1",
          "debtor_actor_id": "22222222-c51c-4bf4-9960-e1c80e27aba1",
          "creditor_actor_id": "33333333-c51c-4bf4-9960-e1c80e27aba1",
          "obligation_type": "other",
          "obligation_kind": "delivery",
          "title": "Entregar contrato firmado",
          "status": "open",
          "due_at": "2026-06-10T18:00:00.000000+00:00"
        }
        """
        let obligation = try decode(Obligation.self, json)
        #expect(obligation.obligationKind == "delivery")
        #expect(obligation.isActionKind)
        #expect(!obligation.isMoneyKind)
        #expect(obligation.title == "Entregar contrato firmado")
    }

    @Test("Obligation legacy sin obligation_kind defaultea a money")
    func obligationLegacyKindDefault() throws {
        let json = """
        {
          "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "debtor_actor_id": "22222222-c51c-4bf4-9960-e1c80e27aba1",
          "creditor_actor_id": "33333333-c51c-4bf4-9960-e1c80e27aba1",
          "obligation_type": "iou",
          "amount": 325,
          "currency": "MXN"
        }
        """
        let obligation = try decode(Obligation.self, json)
        #expect(obligation.obligationKind == "money")
        #expect(obligation.isMoneyKind)
    }

    @Test("complete_obligation result con already_completed=true")
    func completeObligationAlreadyCompleted() throws {
        let json = """
        {"obligation_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1", "status": "completed", "already_completed": true}
        """
        let result = try decode(ObligationCompletedResult.self, json)
        #expect(result.alreadyCompleted)
        #expect(result.status == "completed")
    }

    // MARK: - Reglas legibles

    @Test("descripción legible de reglas")
    func ruleDescriptions() throws {
        let lateRule = Rule(
            id: UUID(),
            contextActorId: UUID(),
            title: "Multa por tarde",
            triggerEventType: RuleTrigger.checkedIn.rawValue,
            conditionTree: RuleConditionBuilder.lateMoreThan(minutes: 15),
            consequences: RuleConsequenceBuilder.fine(amount: 100, currency: "MXN")
        )
        #expect(lateRule.conditionDescription.contains("minutos tarde"))
        #expect(lateRule.conditionDescription.contains("mayor a"))
        #expect(lateRule.consequenceDescription.contains("Multa"))
        #expect(lateRule.consequenceDescription.contains("MXN"))

        let alwaysRule = Rule(id: UUID(), contextActorId: UUID(), title: "Sin condición")
        #expect(alwaysRule.conditionDescription == "Siempre aplica")
    }
}
