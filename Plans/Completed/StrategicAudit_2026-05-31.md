# Auditoría Estratégica Total — Ruul v1

**Fecha:** 2026-05-31
**Método:** verificación directa de migraciones + código iOS, cross-grep entre backend y cliente. Todo verificado salvo `NO VERIFICADO` explícito.
**Pregunta guía:**
1. Si mañana 100 grupos reales usan Ruul, ¿qué se rompe primero?
2. ¿Qué genera más valor para acercarnos a PMF?

---

## Cifras objetivas medidas

- 493 migraciones forward
- 51 tablas, 167 RPCs en migrations
- 24 edge functions (20 cron + 4 ad-hoc)
- 18 funciones `_smoke_*` internas
- 31 features iOS, 29 stores, 26 repositories
- 113 RPCs únicos llamados desde el cliente (centralizados en `SupabaseRuulRPCClient.swift`)
- 54 permission keys en catálogo, 54 rule atoms, 12 decision templates, 14 membership transitions
- RLS habilitado en 50/51 tablas (excepción: `group_rule_engine_quotas`)

---

## PARTE 1 — Inventario por Dominio

| Dominio | Backend | iOS | E2E | Smoke | Estado |
|---|---|---|---|---|---|
| Identity | profiles + my_profile/update_my_profile + Supabase Auth | SignInWithOTPView + ProfileStore + EditProfileView | ✅ | _smoke_identity_rls | SHIPPED-min |
| Groups | groups + group_summary + list_my_groups + create_group_with_admin + group_visibility | GroupsStore + CreateGroupView + GroupSettingsView | ✅ | _smoke_groups_boundary | SHIPPED |
| Membership | group_members + invites + group_membership_boundary + accept_invite + leave_group + set_membership_state + approve_membership_request* + membership_provenance* | MembersStore + MembersListView + MemberDetailView + MembershipStateSheet | ✅ | _smoke_membership_deep | SHIPPED |
| Roles | list_group_roles + create_custom_role + update_role_permissions + assign/revoke_role | RolesStore + RolesListView + RoleEditorView | ⚠️ | _smoke_authority | PARTIAL |
| Permissions | 54 keys + list_member_permissions + list_permissions_catalog | client-side Set.contains en 19 archivos | ✅ | _smoke_permission_keys_audit | PARTIAL |
| Governance | group_decision_rules + set_decision_rules + group_governance_versions + group_boundary_policy | DecisionRulesStore + EditDecisionRulesView + BoundaryPolicyView | ✅ | _smoke_governance | SHIPPED |
| Resources | 18 type whitelist + create_group_resource + group_resources_active + group_resource_detail + 6 series + lifecycle | ResourcesStore + 12 sheets + ResourceDetailView | ✅ | _smoke_resources_b1..b5 | SHIPPED |
| Money | 7 tablas + record_expense/settlement/contribution + issue_sanction + record_pool_charge + group_pool_balance | MoneyDashboardView + 6 sheets + DebtsListView + SettleUpView | ✅ | _smoke_money_flow + _smoke_money_extended | SHIPPED |
| Decisions | start_vote + cast_vote + finalize_vote + execute_decision* + decision_provenance* + apply_decision_template* + decision_templates_catalog 12 | DecisionsStore + DecisionDetailView + Propose/Vote sheets | ✅ | _smoke_governance | SHIPPED |
| Rules | 54 atoms + create_engine_rule + create_text_rule + dispatcher + quota + kill switch* | RulesStore + EditRuleView + RuleEvaluationsView + GroupEngineSettingsView | ✅ | _smoke_rules_engine | SHIPPED-tech / PARTIAL-UX |
| Notifications | notifications_outbox + APNs cron + register_my_notification_token | NotificationSettingsView + AppDelegate APNs. **CERO Inbox in-app** | ⚠️ | _smoke_notifications | PARTIAL |
| Events/system | system_events + group_events + group_events_recent + group_events_for_member + group_events_for_entity | EventsStore + GroupHomeFeedView + GroupHistoryView | ✅ | _smoke_memory_audit | SHIPPED |
| Provenance | system_event_engine_provenance + decision_provenance* + membership_provenance* + lineage | WhyDidThisHappenSheet inline | ✅ | _smoke_memory_audit | PARTIAL |
| Rituals | **CERO tabla, CERO RPC** | 3 vistas iOS sin backend | ❌ | 0 | STUB FRONT-ONLY |
| Memory | system_events feed + group_events_for_member | GroupHistoryView + MemberHistoryView | ✅ | _smoke_memory_audit | PARTIAL |
| Search | CERO | CERO | ❌ | 0 | ABSENT |
| Founder UX | group_foundation_status + identity_atoms | FoundationStatusCard + ProfileOnboardingNudge | ⚠️ | 0 | PARTIAL |
| Admin UX | role=admin gates + 54 permissions | Acciones en MemberDetail + GroupSettings. No dashboard dedicado | ⚠️ | 0 | PARTIAL |

`*drift` = RPC llamado por iOS, migración NO commiteada en `supabase/migrations/`.

---

## PARTE 3 — Primitive Scores

| Primitiva | Score | Pregunta |
|---|---|---|
| Members | 85/100 | ✅ Una comunidad puede gestionar quién pertenece |
| Resources | 80/100 | ✅ Puede gestionar recursos reales (asset/fund/space/slot/right) |
| Money | 82/100 | ✅ Puede administrar dinero (pool + peer + sanciones + cuotas) — el más maduro |
| Decisions | 78/100 (65/100 si penalizamos drift) | ✅ Puede gobernarse (propose/vote/execute autónomos) |
| Rules | 70/100 | ✅ Puede automatizarse (engine real con kill switch + quota) |
| Governance | 75/100 | ✅ Existe (no implícita): quorum, threshold, versioning, dissolution |
| Rituals | 10/100 | ❌ No existe pese a vistas iOS que mienten |
| Memory | 55/100 | ⚠️ Timeline+feed sí; memoria narrativa no |

---

## PARTE 4 — E2E Reality Check

| Caso | Funciona hoy | Qué falta |
|---|---|---|
| Familia (padres/hijos/patrimonio) | ⚠️ parcial | Roles parentales first-class, herencia, presencia de menores sin auth, valuación legal |
| Comunidad religiosa | ✅ mínimo viable | Tiers de membresía, cadencia ritual (Rituals roto), difusión a toda la comunidad (sin Inbox), calendario común |
| Cooperativa | ⚠️ alta cobertura técnica, baja legalidad | Estados de cuenta exportables, auditoría externa, firma electrónica, conformidad fiscal |
| Asociación civil | ⚠️ alta cobertura técnica | Comités como agregado primitivo, actas oficiales, quórum de comité |

**Resumen:** hoy Ruul puede ser usado por una familia ampliada o comunidad pequeña que reparte gastos + decide cosas chicas + tiene 2-3 recursos compartidos. NO está listo para entidad legal con responsabilidad fiscal externa.

---

## PARTE 5 — Orphan Detection

| Objeto | Tipo | Por qué huérfano |
|---|---|---|
| RitualsListView + CreateRitualSheet + EditRitualSheet | iOS sin backend | No existe tabla ni RPC `rituals_*` |
| Search | conceptual | 0 implementación |
| `group_rule_engine_quotas` | tabla sin RLS | Único caso (50/51) — posible intencional, no documentado |
| `Members/Profile/Resource/Rule*PreviewData` | Preview only | OK pero confunde auditoría |
| `cancel_vote` RPC | en RPC client, sin UI | Estado alcanzable, no expuesto |
| `group_rule_evaluation_summary` + `rule_evaluation_summary` | redundantes | Ambos llamados, redundancia NO VERIFICADA |
| `templates` table picker | seedeada | NO VERIFICADO consumo desde CreateGroupView |
| `promote_norm_to_rule` (manual) vs auto-promote trigger | doble path | Confuso |
| `group_resource_series` (3 RPCs) | backend | NO VERIFICADO consumo iOS |
| Inbox in-app | vista | Backend dispatch funciona, vista no existe |
| ~38 RPCs declarados no llamados desde iOS | backend | Muchos `_*` internos, resto candidatos a orphan |

---

## PARTE 6 — Contradicciones

| Hallazgo | Severidad | Evidencia |
|---|---|---|
| 🔴 **Migration drift D.17-D.20** aplicadas vía MCP, SQL NO commiteado | CRÍTICA | Grep en `supabase/migrations/` para `set_group_engine_active`, `engine_active`, `approve_membership_request`, `execute_decision`, `decision_provenance`, `apply_decision_template`, `membership_provenance` → 0 archivos. iOS las llama. Reproducibilidad rota. |
| 🔴 **Rituals UX engaña**: backend cero, iOS 3 vistas | ALTA | Sin tabla ni RPC. Usuarios verán "Rituales" y se romperán. |
| 🟠 **Sin Inbox in-app** | ALTA | 0 archivos iOS mencionan "Inbox" o "notifications_outbox". Si apagas push, pierdes el evento. |
| 🟠 Permission gating client-side puro | MEDIA | iOS hace `Set.contains` post-fetch. NO HAY auditoría de qué keys se gatean en UI vs cuáles en backend. |
| 🟠 `Search` prometido en CLAUDE.md, no existe | MEDIA | Doctrina menciona Search; código = 0 |
| 🟡 `cancel_vote` sin UI | MEDIA | Backend alcanzable, no expuesto |
| 🟡 `governance_versions` sin vista | MEDIA | Historia de cambios al quorum no se muestra |
| 🟡 `templates` picker NO VERIFICADO en CreateGroupView | MEDIA | Doctrina dice "templates inicializan grupo" |
| 🟡 Founder UX ≠ Admin UX colapsados | MEDIA | Backend role=admin sí, founder no first-class |
| 🟡 `group_rule_engine_quotas` sin RLS | BAJA-MEDIA | Posiblemente intencional, no documentado |

---

## PARTE 7 — PMF Audit

### Lo que SÍ puede hacer hoy un grupo real
- Convivir y registrar quién pertenece (invitar, aceptar, pausar, remover, banear)
- Compartir gastos como Splitwise + sanciones + mandates
- Cobrar cuotas/buy-ins al pool común
- Tener un fondo común visible
- Decidir cosas (proponer/votar/ejecutar) con quórum y threshold ajustables
- Disputar una sanción y escalar a voto
- Tener reglas con engine que disparen consecuencias automáticas
- Promover una norma cultural a regla formal
- Compartir recursos físicos (18 tipos) con lifecycle real
- Ver historia "qué pasó" y "por qué pasó esto"
- Recibir push notifications fuera de la app
- Disolver el grupo ordenadamente

### Lo que NO puede hacer todavía
- Inbox in-app → si pierdes el push, pierdes el evento
- Buscar — encontrar la decisión X de hace 2 meses es imposible
- Rituales/cadencias — recurrencia prometida no existe
- Memoria narrativa
- Founder/Admin tooling diferenciado
- Reportes exportables (no apto legal/fiscal)
- Onboarding emocional fuerte
- Discoverability de recursos
- Comités/sub-agrupaciones
- Importación de datos previos

---

## PARTE 8 — Bottleneck #1

**Drift entre repo de migraciones y live DB.**

**Descripción:** D.17/D.18/D.19/D.20 aplicadas en vivo vía `mcp__supabase__apply_migration`, SQL nunca commiteado a `supabase/migrations/`. iOS llama esos RPCs.

**Impacto:**
- Reproducibilidad rota: clonar repo + `supabase db reset` deja la app rota
- Onboarding colaborador/staging: roto
- Si Supabase pierde estado → primitivas críticas desaparecen
- Code review serio imposible
- "Migrations son la fuente única" (CLAUDE.md) es **falso hoy**

**Qué impide:** deploy a segundo proyecto, open-source, branching preview, auditoría legal, tests con reset DB.

**Qué desbloquea:** 100 grupos en staging idéntico a producción + CI/CD real + confianza en que el código que ves es el código que corre.

**Por qué importa más que todo lo demás:** cualquier feature nueva se construye sobre arena. El día que necesites recrear el ambiente (incidente, fork de cliente, transferencia a co-founder, branch preview, contrato con partner) descubres que la mitad reciente no existe en el código. Deuda silenciosa que se vuelve catastrófica al materializarse.

---

## PARTE 9 — Roadmap Recommendation

**D.21 — Repo Truth + In-App Inbox** (ver `Plans/Active/D21_RepoTruth_Inbox.md`).

Duración: 1–2 sesiones.

**Por qué NO Governance todavía:** está al ~75%; doctrina founder dice "post-v2 consolidation phase — NOT feature phase".

**Por qué NO Rituals todavía:** doctrina "Ontology freeze after Paso 4 — no nuevas primitivas sin override explícito". Las 3 vistas iOS deben marcarse "Próximamente" o eliminarse.

**Por qué NO Memory todavía:** memoria narrativa requiere LLM/índice semántico; sin volumen de datos real no aporta valor.

**Lookout post-D.21 (sin compromiso):** D.22 Search MVP → D.23 Founder/Admin UX split → D.24 Rituals real → D.25 Memory narrative.

---

## PARTE 10 — Founder Report

| Capa | % |
|---|---|
| Infraestructura | 88% |
| Producto | 72% |
| Usabilidad | 55% |
| Gobernanza | 78% |
| Diferenciación | 65% |
| Probabilidad de uso real HOY | 45% |
| PMF tras D.21 | 30% inmediato → 55% siguiendo roadmap lookout |

### Conclusión ejecutiva

Ruul tiene la mejor infraestructura de su categoría: 493 migraciones, 167 RPCs, engine de reglas determinístico con dispatcher, quota y kill switch, primitiva Money probada en device, primitiva Decisions promovida a autónoma, Membership con 14 transiciones catalogadas, Resources con 18 tipos y lifecycle real. Lo que no tiene es **fidelidad entre lo que dice y lo que muestra**: cuatro fases recientes están en el live DB y no en el repo, Rituals aparece en la UI pero no existe en backend, Inbox no existe pese a tener el outbox completo, y Search está en doctrina pero no en código. El usuario final NO ve el engine — ve botones bonitos sobre una máquina poderosa que no se publicita a sí misma.

La pregunta "¿qué se rompe primero si mañana hay 100 grupos?" tiene una respuesta operacional, no técnica: se rompe la reproducibilidad (no puedes clonar el ambiente), la legibilidad del estado (no hay Inbox), y la confianza emocional del usuario (Rituals miente).

La pregunta "¿qué genera más valor hacia PMF?" tiene la misma respuesta: cerrar la brecha entre lo que existe en código y lo que el usuario percibe — empezando por commitear lo aplicado, exponer el engine vía Inbox, y eliminar promesas rotas.

PMF no se gana agregando primitivas; se gana cuando lo que ya construiste se ve, se entiende y se puede reproducir.
