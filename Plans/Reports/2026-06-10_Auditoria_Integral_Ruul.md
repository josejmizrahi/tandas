# Auditoría Integral Ruul — 2026-06-10

Revisión profunda de backend (221 migraciones MVP2), iOS (RuulCore + RuulApp, ~31.5k líneas
de features), contrato y doctrina, realizada como un solo sistema. Evidencia verificada
contra código real; los hallazgos inciertos se marcan como tales.

---

## 0. Diagnóstico brutalmente honesto

**Lo primero: el núcleo está bien diseñado.** Esto no es un proyecto roto. La doctrina
actor/contexto/obligación es coherente y está implementada de verdad: obligations como
primitiva universal de compromiso, settlement por novación con guard de recursión e
idempotencia, `numeric` en todo el dinero (cero floats), SECURITY DEFINER con
`search_path` explícito y deny-by-default en grants, activity append-only con weak refs
que sobreviven deletes, smokes-como-migraciones, y en iOS una arquitectura intent-first
que en su mayoría se respeta, con un mock de 5,000 líneas en paridad real. Eso es mejor
ingeniería que el 90% de los MVPs.

**El problema real no es diseño: es velocidad sin consolidación.** Hoy (2026-06-10) hay
**tres motores a medio terminar al mismo tiempo** (R.6 reglas, R.7 gobernanza, R.8 pools),
**tres sistemas paralelos de "atención"** (rule_attention_items, attention_inbox(),
notifications R.4D), **dos vistas de detalle de recurso conviviendo** (V1 + V2), un
contrato iOS **desactualizado por ~25 RPCs**, y la racha `R.5Z.fix.*` metió 10+ RPCs
nuevos de los cuales **ninguno emite activity** — justo en el producto cuya tesis es
"memoria institucional auditable".

**Y un punto incómodo: tu propio modelo mental del backend está desactualizado.**
No existen `group_rules`, `group_rule_versions` ni compat views de `group_resources`.
El reset MVP2 (mvp2_000) eliminó todo eso; las tablas son `rules` y `resources` nativas,
sin capa de compatibilidad. Tampoco hay "templates de decisión heredados": son
`decision_templates` + catálogo R.4B. Si el founder opera con un mapa viejo, las
decisiones de arquitectura se toman contra un sistema que ya no existe. Este reporte
es también la corrección de ese mapa.

**Las grietas graves están en las costuras entre dominios**, no dentro de cada dominio:

1. El reparto de gastos ponderado (+N, invitados) se calcula **en iOS**
   (`RecordExpenseView.swift` — `EventExpenseScope.weights`), no en backend. Viola
   "backend = autoridad" y deja el audit trail sin la base del cálculo.
2. `event_guests` está huérfano del modelo de dinero: `record_expense` reparte por
   default entre miembros activos; los invitados solo entran si iOS los pondera a mano.
3. El ledger R.4C solo mapea `expense` y `payment`
   (`20260604130001_r4c_ledger_fix_split_role_mapping.sql:26-40`): settlements, multas,
   contribuciones y payouts **no generan asientos**. El producto ya lo rodeó (commit
   `ff303ba` lee balance desde obligations) — el ledger es un sistema sombra semi-muerto.
4. Pools R.8: el dinero puede **entrar** (`create_pool`, `contribute_to_pool`) pero no
   puede **salir** (`resolve_pool` / R.8.C no existe). Obligaciones `pending_pool` sin
   camino de resolución, shipped hoy.
5. ~10 RPCs mutantes recientes sin `emit_activity`: add/remove_event_guest,
   add/remove_event_participants, set_plus_one/plus_count, host_confirm_participant,
   dismiss_attention_item y — el peor — `claim_placeholder_actor`, que reasigna
   memberships, obligations, splits y participants en bloque, invisible para la auditoría.
6. Gobernanza R.7 con bypass conocido: `large_expense` está en el catálogo con
   `default_requires_decision=true` pero `record_expense` no lo consulta. Además el
   guard anti doble-ejecución es un check de status sin lock (carrera teórica).
7. `record_fine` y `record_game_result` no son idempotentes (sin `client_id`): doble
   tap = obligaciones duplicadas.
8. 8 pares de migraciones con timestamp duplicado (verificado), incluyendo
   `20260610230000` compartido por settlement-appeal y pool-schema. El orden de replay
   hoy es determinista por sufijo alfabético — funciona de chiripa.

**Falsa alarma descartada:** una pasada automática sugirió "10+ tablas sin policy RLS".
Verificado contra los archivos: `resources`, `money_transactions`, `calendar_events`,
`decisions`, `settlement_*`, `obligations`, etc. **sí tienen policies**. Queda por
confirmar contra la BD viva un grupo de tablas de catálogo/secciones/widgets (lectura
vía RPC), pero no hay evidencia de hoyo RLS en datos sensibles.

**En iOS** la arquitectura es sana pero hay deuda concentrada: god-views
(`EventDetailView` 2,017 líneas, `ContextDetailViewV2` 1,981, `ResourceDetailViewV2`
1,665), 7-8 switches hardcodeados sobre action keys en vistas, un `switch resource.type`
en `ResourceDetailView.swift:326` (violación directa de doctrina F.2X), las tres vistas
más grandes **sin preview** (viola tu propia regla "toda vista tiene preview"), formato
de moneda duplicado, y el anómalo "Espacio" en `ClaimPlaceholdersSheet` contra
"Contexto"/"Grupo" en el resto.

**Veredicto:** Ruul no necesita re-arquitectura. Necesita **una pausa de consolidación
de ~2 semanas** antes de seguir apilando motores: cerrar los tres motores a medias,
unificar atención, devolver la autoridad del dinero al backend, tapar los hoyos de
auditoría y re-sincronizar el contrato. Si sigues construyendo R.9 encima de esto, las
costuras se convierten en deuda estructural.

---

## 1. Mapa conceptual de Ruul (estado real)

```
actors (person | collective | legal_entity | system)
  ├─ contexto = actor collective con is_context=true (NO hay tabla contexts)
  ├─ pool     = actor collective subtype='pool' + pool_accounts (R.8)
  └─ placeholder = actor person sin auth_user_id (R.5W), reclamable

actor_memberships (estados: invited/requested/active/paused/left/removed/banned)
roles + role_permissions + role_assignments + permission_catalog (25 permisos)
resources + resource_rights (OWN/USE/MANAGE/VIEW/SELL/TRANSFER/GOVERN…)
  └─ clases/subtipos/secciones/widgets/action-forms (R.5A, parcialmente inerte en UI)
calendar_events + event_participants + event_guests (R.5Z, MVP1, fuera del modelo money)
resource_reservations (+ source_event_id opcional, doctrina R.2T)
rules (condition_tree DSL cerrado R.6.D) → consecuencias: fine | create_obligation | emit_attention
  └─ disparo: trigger sobre activity (R.6.B) + detectores pg_cron (R.6.C)
decisions + decision_options + decision_votes + decision_templates (dispatcher R.4B)
governance_action_catalog + governance_actions + governance_policies (R.7, modelo PULL)
obligations = primitiva universal (money + action; estados open→settled/forgiven/disputed/…/pending_pool)
money_transactions + money_splits → settlement_batches/items (novación viva R.2N,
  handshake 2-vías + apelación R.5Z) → ledger_entries (R.4C, incompleto)
activity_events (append-only, weak refs) + activity_event_catalog
atención: rule_attention_items ∥ attention_inbox() ∥ notifications  ← 3 sistemas
```

Lectura correcta del modelo: **el contexto ya ES el actor colectivo** (doctrina cumplida),
pero su agencia económica es asimétrica: puede ser acreedor de multas, no es parte en
gastos, y el pool es un actor hermano, no el contexto. Eso es una decisión pendiente
(ver §13).

## 2. Modelo backend ideal (respetando lo existente)

No se necesitan tablas nuevas. Se necesita cerrar costuras:

- **Dinero con autoridad en backend**: `record_expense` debe aceptar
  `p_source_event_id` + `p_split_basis` (`equal` | `event_weights` | `explicit`) y
  calcular pesos (1 + plus_count + guest count_share) **en SQL**, persistiendo la base
  del cálculo en metadata. iOS solo previsualiza (RPC `preview_event_split` opcional).
- **Invitados dentro del modelo**: opción mínima (recomendada): los guests pesan en el
  split del participante que los invitó (ya casi es el modelo actual — formalizarlo en
  backend). Opción futura: guest → placeholder actor si debe deber dinero por sí mismo.
  No crear una tercera vía.
- **Ledger: decidir, no arrastrar**. O se completan los mapeos (settlement, fine,
  contribution, payout, game_result) y `actor_money_balances` vuelve a ser confiable,
  o se archiva el ledger y el balance canónico queda en obligations (que es lo que el
  descriptor ya hace). Mantener ambos a medias es el peor mundo.
- **Pools**: terminar R.8.C (`preview_pool_resolution` + `resolve_pool` con
  `winner_takes_all` y `equity_target`), smokes r8_b/r8_c, y wiring de gobernanza
  (`pool.resolve` en `governance_action_catalog`, dangerous=true).
- **Auditoría total**: `emit_activity` en los ~10 RPCs que no lo hacen; tipos nuevos en
  `activity_event_catalog`. Smoke genérico: "todo RPC mutante del catálogo emite activity".
- **Atención unificada**: `rule_attention_items` se generaliza a `attention_items`
  (renombre lógico, no físico: ya es la tabla que todos usan como sink),
  `attention_inbox()` queda como **única** lectura agregadora, y `notifications` R.4D
  se reduce a capa de entrega (push/digest) alimentada desde attention — o se archiva
  hasta que haya push real.
- **Gobernanza sin bypass**: `record_expense` consulta `_governance_action_approved()`
  cuando supera el umbral de `large_expense`; `execute` paths toman
  `select … for update` sobre `governance_actions`/`decisions` antes del check de status.
- **Idempotencia pareja**: `client_id` en `record_fine`, `record_game_result`,
  y en los RPCs R.5Z de eventos.

## 3. Modelo frontend ideal

- Mantener: 3 gates, 5 tabs F.NAV, stores por pantalla con `StorePhase`,
  `UserFacingError`, ActionRouter/ActionPresentationCatalog.
- **Un solo detalle de recurso**: migrar los call-sites de `ResourceDetailView` (V1) a
  V2 y borrar V1 (1,325 líneas muertas-vivas). El `switch resource.type` de V1 muere
  con él.
- **Routing de acciones centralizado**: los 7-8 `switch actionKey` de vistas
  (`ContextDetailViewV2:1754`, `EventDetailView:1099`, `MoneyHomeView:421`,
  `ObligationDetailView:289`…) se mueven a `ActionRouter` con un solo mapa
  actionKey→destino y telemetría de "action key desconocida".
- **Descomponer god-views** por secciones ya marcadas con MARK (EventDetail: header /
  participantes / dinero / acciones; ContextDetailV2: descriptor / tabs / quick actions).
- Previews para las 3 vistas grandes + `ObligationDetailView` (regla DoD propia).
- Utilidad única de formato de moneda (extensión en RuulCore) y label único de subtipo
  de contexto ("Contexto" fallback, "Grupo" para friend_group; eliminar "Espacio").

## 4. Inconsistencias detectadas (consolidado)

| # | Inconsistencia | Evidencia | Severidad |
|---|---|---|---|
| 1 | Split ponderado calculado en iOS, backend lo ignora | `RecordExpenseView.swift` weights; `mvp2_009:123-126` default = miembros activos | **Crítica (doctrinal)** |
| 2 | `event_guests` fuera del modelo money | `20260610190000`; record_expense no los considera | Alta |
| 3 | Ledger sin mapeos settlement/fine/contribution/payout | `r4c_fix_split_role_mapping.sql:26-40` (`else null`) | Alta |
| 4 | Pools sin resolución (dinero entra, no sale) | r8_a/r8_b shipped; R.8.C inexistente | Alta |
| 5 | ~10 RPCs mutantes sin emit_activity (incl. claim_placeholder) | `20260610170000/180000/190000/200000`, `r5w_claim_slice4` | Alta |
| 6 | Bypass gobernanza en `record_expense` (large_expense) | catálogo r7_a:259-271 sin enforcement | Media-Alta |
| 7 | `record_fine`/`record_game_result` sin idempotencia | mvp2_009 sin client_id | Media-Alta |
| 8 | 3 sistemas de atención paralelos | r6_a sink ∥ f_nav_0 inbox ∥ r4d notifications | Media |
| 9 | 8 pares de timestamps de migración duplicados | `20260610230000` ×2, `20260608220000` ×2, 6 más | Media |
| 10 | Contrato iOS desactualizado ~25 RPCs; CLAUDE.md ídem | `MVP2_iOS_Contract.md` (últ. update 06-09) | Media |
| 11 | iOS: V1+V2 resource detail conviven; switch sobre resource.type | `ResourceDetailView.swift:326`; `MyResourcesView:55` | Media |
| 12 | iOS: switches actionKey en vistas (7-8) | ver §3 | Media |
| 13 | God-views sin preview (EventDetail 2017 L, ContextDetailV2 1981 L, ResourceDetailV2 1665 L) | RuulApp/Features | Media |
| 14 | obligation 'open' mientras settlement_item 'pending_confirmation' (UX de balance confusa) | `20260610220000:128-137` | Media |
| 15 | Reglas pueden multar a ex-miembros (sin snapshot de membership) | r6_b eval core | Media |
| 16 | `remove_member` no trata obligations/votes/settlement abiertos del removido | mvp2_002 + r7_x_1 | Media |
| 17 | Smokes faltantes: r8_b, claim placeholder, guests, plus_count, host_confirm | cadena de migraciones | Media |
| 18 | Consecuencia de regla "notification" no ejecutable (solo fine/obligation/attention) | r6_b | Baja |
| 19 | "Espacio" vs "Contexto"; formato moneda duplicado | `ClaimPlaceholdersSheet:226`; ContextDetailV2:1539 + ResourceDetailV2:1492 | Baja |
| 20 | Doc R8 dice "pendiente" pero A/B ya shipped; R.5Z.fix.* fuera del roadmap | Plans/Active | Baja |

## 5. Plan de reparación por fases

**Fase 0 — Higiene inmediata (½ día, riesgo nulo)**
Renombrar timestamps duplicados (solo los no aplicados aún en remoto — verificar
`supabase migration list` antes); actualizar `MVP2_iOS_Contract.md` y CLAUDE.md con los
~25 RPCs faltantes; marcar R8 doc como "A/B shipped".

**Fase 1 — Auditabilidad y seguridad (1-2 días, riesgo bajo)**
emit_activity en los 10 RPCs + catálogo; client_id en record_fine/record_game_result;
`for update` en execute de decisiones/gobernanza; smoke "todo RPC mutante emite activity";
auditoría RLS contra BD viva (pg_policies) con smoke que asserte policy ≥1 por tabla RLS.

**Fase 2 — Dinero con autoridad en backend (2-3 días, riesgo medio)**
`record_expense` con split_basis/event_weights server-side (guests + plus_count);
decisión ledger (completar o archivar — recomendación: **completar mapeos**, es 1
migración, y conservar doble verificación); sincronizar obligation status con
pending_confirmation (o exponer estado compuesto en descriptor).

**Fase 3 — Cerrar pools R.8 (2-3 días, riesgo medio)**
R.8.C resolve/preview con winner_takes_all + equity_target; gobernanza pool.resolve;
smokes r8_b/r8_c; iOS R.8.E/F mínimo (lista + detalle + contribuir, nombres por
policy_key: Bote/Kitty/Fondo/Tanda).

**Fase 4 — Unificar atención (2 días, riesgo medio)**
attention_inbox() como única lectura; rule_attention_items como único sink (generalizar
naming en código, no migrar tabla); decidir destino de notifications R.4D (congelar
hasta push). iOS: AttentionInboxStore como única fuente del tab 🔔 + badges.

**Fase 5 — Consolidación iOS (3-5 días, riesgo bajo)**
Matar ResourceDetailView V1; centralizar routing en ActionRouter; partir god-views;
previews faltantes; unificar moneda y labels; "Espacio"→"Contexto".

**Fase 6 — Gobernanza completa (después de R.5Z sign-off)**
Enforcement large_expense; snapshot de membership en evaluación de reglas y votos;
remove_member con manejo de obligaciones abiertas (bloquear, transferir o forgive
explícito vía gobernanza).

## 6. Qué NO tocar

- El reset MVP2 y la cadena de migraciones aplicadas (aditivo siempre; nunca editar
  migraciones ya aplicadas — solo renombrar timestamps de archivos aún no aplicados).
- La primitiva obligations universal y el motor de novación R.2N (bien diseñados).
- El modelo pool-como-actor (decisión founder correcta: evita duplicar el grupo).
- La arquitectura de 3 gates + 5 tabs + stores por pantalla en iOS.
- ActionPresentationCatalog/ActionRouter como patrón (solo reforzarlo).
- Los nombres canónicos de RPCs que iOS ya consume.
- El patrón smokes-como-migraciones.

## 7. Qué arreglar YA (esta semana)

Fases 0-2: timestamps, contrato, activity en los 10 RPCs, idempotencia de multas/juegos,
split server-side, decisión ledger, y los smokes de R.8.b. Todo lo demás puede esperar
al sign-off de R.5Z.

## 8. Prompts de implementación (Cursor/Codex/Claude Code)

**P0 — Higiene de migraciones y contrato**
> En /supabase/migrations hay 8 pares de archivos con el mismo timestamp (ej.
> `20260610230000_r5z_fix_settlement_appeal.sql` y `20260610230000_r8_a_pool_primitive_schema.sql`).
> Verifica con `supabase migration list` cuáles ya están aplicadas en remoto; renombra
> SOLO los archivos no aplicados sumando segundos para preservar el orden actual
> (alfabético por sufijo). Después actualiza `Plans/Active/MVP2_iOS_Contract.md` y la
> tabla de RPCs de `CLAUDE.md` agregando: RPCs R5Z (add/remove_event_guest,
> add/remove_event_participants, set_event_participant_plus_one/plus_count,
> host_confirm_participant, confirm/reject/appeal_settlement_paid,
> dismiss_attention_item), R7 (set_membership_state, transfer_resource_ownership,
> archive_rule, forgive_obligation), R8 (create_pool, contribute_to_pool,
> list_context_pools, pool_account_detail) y R5A (resource_detail_descriptor,
> context_detail_descriptor, list_resource_actions, execute_resource_action), con
> shapes wire reales extraídos de las migraciones. No cambies firmas.

**P1 — Audit trail completo**
> Crea una migración `r9_a_activity_gap_closure` que: (1) agregue `_emit_activity` a
> add_event_guest, remove_event_guest, add_event_participants,
> remove_event_participants, set_event_participant_plus_one,
> set_event_participant_plus_count, host_confirm_participant, dismiss_attention_item y
> claim_placeholder_actor (este último debe emitir un evento por cada dominio
> reasignado: membership, obligations, splits, participants, con counts en metadata);
> (2) registre los nuevos event_types en activity_event_catalog; (3) incluya un smoke
> `_smoke_r9_a_activity_coverage` que ejecute cada RPC y asserte el incremento en
> activity_events. Usa CREATE OR REPLACE conservando firmas y permisos exactos
> (revoke public/anon, grant authenticated). Patrón de referencia:
> `20260610230000_r5z_fix_settlement_appeal.sql` que sí emite activity.

**P1b — Idempotencia multas/juegos**
> Migración `r9_b_money_idempotency`: agrega parámetro `p_client_id text default null`
> a `record_fine` y `record_game_result` siguiendo exactamente el patrón D9 de
> `record_expense` (mvp2_009:111-116): unique index parcial sobre
> (created_by_actor_id, client_id) y retorno de la fila existente en duplicado.
> Mantén las firmas viejas como overload deprecado que delega, para no romper iOS.
> Smoke que llama dos veces con el mismo client_id y asserte una sola obligación.

**P2 — Split server-side**
> Migración `r9_c_event_weighted_split`: extiende `record_expense` con
> `p_source_event_id uuid default null` y `p_split_basis text default 'equal'`
> ('equal'|'event_weights'|'explicit'). Con 'event_weights': peso por participante =
> 1 + coalesce(plus_count,0) + sum(count_share de event_guests vivos invitados por él);
> monto = round(total*peso/suma_pesos, 2) con ajuste de centavos al payer. Persiste
> `split_basis` y los pesos en metadata de la transacción. Agrega RPC read-only
> `preview_event_split(event_id, amount)` que devuelva el desglose. En iOS, cambia
> `RecordExpenseView`/`EventExpenseScope` para usar preview_event_split como fuente y
> enviar split_basis en lugar de montos calculados localmente (mantén el modo manual
> como 'explicit'). Smokes: 5 miembros + 1 con plus_count=2 + 1 guest count_share=1.

**P2b — Ledger completo**
> Migración `r9_d_ledger_complete_mappings`: en `_emit_ledger_from_split` y la vista de
> backfill (`r4c_ledger_fix_split_role_mapping.sql`), agrega mapeos para
> transaction_type IN ('settlement','fine','contribution','payout','game_result') con
> la convención debit/credit coherente con expense/payment. Backfill de splits
> históricos sin asiento. Smoke: tras mark+confirm de un settlement, la suma de
> ledger_entries por (context,currency) es cero y `actor_money_balances` coincide con
> obligations open.

**P3 — Pools R.8.C**
> Implementa R.8.C según `Plans/Active/R8_PoolPrimitive.md` §3: RPCs
> `preview_pool_resolution(pool_account_id)` (read-only, calcula payouts según
> policy_key) y `resolve_pool(pool_account_id, p_resolution jsonb, p_client_id)` para
> winner_takes_all y equity_target. resolve_pool: valida autoridad (money.settle del
> contexto padre), gate de gobernanza vía `_governance_action_approved()` con nueva
> entrada `pool.resolve` (dangerous=true) en governance_action_catalog, transiciona
> obligations pending_pool, crea money_transactions tipo payout, emite
> pool.resolved/pool.payout en activity (registrar en catálogo). Smokes para ambas
> policies + idempotencia + intento sin autoridad. Agrega también los smokes faltantes
> de r8_b (create/contribute/list/detail).

**P4 — Atención unificada**
> Audita los tres sistemas (rule_attention_items + emit sink r6_a; attention_inbox()
> f_nav_0; notifications r4d). Propón y aplica: attention_inbox() como única lectura
> agregadora leyendo rule_attention_items + invitaciones + votos pendientes +
> governance pending (r7_g); todo nuevo "necesita tu atención" pasa por
> `_r6_emit_attention`; congela notifications R.4D (no borrar tablas; documentar como
> capa de entrega futura). En iOS, AttentionInboxStore como única fuente del tab
> Actividad/badges. Verifica que dismiss_attention_item cubra todos los kinds.

**P5 — Consolidación iOS**
> (1) Migra MyResourcesView y demás call-sites de ResourceDetailView a
> ResourceDetailViewV2 y elimina V1 (con su switch sobre resource.type, prohibido por
> F.2X). (2) Mueve los switch sobre actionKey de ContextDetailViewV2:1754,
> EventDetailView:1099, MoneyHomeView:421 y ObligationDetailView:289 a ActionRouter
> (mapa único actionKey→ActionDestination; log para keys desconocidas). (3) Extrae
> secciones de EventDetailView y ContextDetailViewV2 a subviews por MARK (<600 líneas
> por archivo). (4) Agrega #Preview con MockRuulRPCClient.demo() a
> ContextDetailViewV2, ResourceDetailViewV2, ObligationDetailView. (5) Unifica formato
> de moneda en RuulCore y reemplaza los dos formatCurrency privados. (6) Reemplaza
> "Espacio" por "Contexto" en ClaimPlaceholdersSheet:226. Compila sin warnings y corre
> los tests del package.

**P6 — Gobernanza sin bypass**
> Migración `r9_e_governance_hardening`: (1) en `record_expense`, si el contexto tiene
> policy large_expense activa y amount supera el umbral (metadata del catálogo),
> requerir `_governance_action_approved()`; (2) en `execute_decision` y
> `execute_governance_action`, `select … for update` de la fila antes del check
> status='executed'; (3) snapshot: `_r6_eval_rules_core` ignora subject actors cuya
> membership no esté active al momento del evento; (4) `remove_member` falla con error
> tipado si el miembro tiene obligations open (mensaje accionable: saldar o perdonar
> vía gobernanza primero). Smokes para los cuatro.

## 9. Checklist de pruebas Supabase

- [ ] `supabase db reset` replay completo de la cadena sin errores (valida orden de timestamps)
- [ ] Todos los `_smoke_mvp2_*` y `_smoke_r*` pasan en local (workflow edge-tests)
- [ ] pg_policies: toda tabla con RLS tiene ≥1 policy o está documentada como RPC-only
- [ ] Funciones SECURITY DEFINER: ninguna ejecutable por anon (`information_schema.routine_privileges`)
- [ ] Doble llamada record_expense/record_fine/record_game_result con mismo client_id → 1 sola fila
- [ ] Gasto con event_weights: suma de splits = total, centavos al payer, guests ponderados
- [ ] Settlement: generate → mark → confirm → ledger suma cero y balance = obligations
- [ ] Apelación: appeal → resolución admin → estados finales coherentes (sin estados zombi)
- [ ] Pool: create → contribute ×2 (idempotente) → preview → resolve → obligations pending_pool cerradas y payouts emitidos
- [ ] Regla demo (r6_f): check-in tarde dispara multa exactamente una vez (re-evaluación no duplica)
- [ ] claim_placeholder_actor: activity emitida por dominio; conteos correctos
- [ ] Gobernanza: acción gated sin decisión aprobada → error governance_required; con decisión → ejecuta una sola vez bajo concurrencia
- [ ] get_advisors (security + performance) sin hallazgos nuevos

## 10. Checklist de pruebas iPhone (simulador iOS 26 / device JJ)

- [ ] Onboarding: OTP → ensure_person_actor → shell (sin pantalla blanca entre gates)
- [ ] Crear grupo (Cena Semanal) → invitar → join por código → miembro visible
- [ ] Evento: crear → RSVP → +N → agregar invitado externo → host confirma → check-in
- [ ] Gasto desde evento: preview de split muestra pesos (×N) idénticos a lo que registra backend
- [ ] Settlement: generar → marcar pagado (deudor) → confirmar (acreedor) → balance llega a cero en descriptor
- [ ] Apelar un pago → admin resuelve → atención desaparece del inbox
- [ ] Pool "Bote": crear → contribuir → resolver → ganador recibe payout (cuando R.8.C exista)
- [ ] Decisión: crear → votar (mayoría) → cerrar → ejecutar (template) → activity registrada
- [ ] Regla: crear "multa por llegar tarde" → check-in tarde → multa aparece en obligaciones
- [ ] Placeholder: crear "Tío Abe" → split lo incluye → claim → deudas transferidas visibles
- [ ] Tab 🔔: cada tipo de atención (voto pendiente, pago por confirmar, conflicto, invitación) navega al detalle correcto y se puede descartar
- [ ] Sin red / error backend: toda pantalla muestra error en español con retry (nunca mensaje crudo)
- [ ] Estados vacíos: contexto nuevo sin recursos/eventos/dinero muestra empty states con CTA
- [ ] Acciones gateadas: usuario sin permiso no ve el botón (available_actions), y si fuerza la acción recibe error claro

## 11. Naming UX recomendado

| Interno | UI recomendada |
|---|---|
| context | **"Grupo"** como término por defecto en UI de consumo (friend_group, familia, viaje); "Contexto" solo en ajustes avanzados. Eliminar "Espacio" salvo "Mi espacio" (contexto personal) |
| pool | Por policy_key: winner_takes_all → "Bote"; equal_share → "Fondo común" (no "Kitty" — anglicismo); proportional → "Fondo"; rotational → "Tanda" (es EL nombre de la app: oportunidad de marca); custom → "Cuenta" |
| obligation (money) | "Deuda" / "Te deben" |
| obligation (action) | "Compromiso" (consistente con Task_Primitive_Evaluation) |
| settlement | "Cuentas claras" / "Saldar cuentas" (nunca "settlement" ni "neteo") |
| governance action | "Requiere votación" (badge), no "acción de gobernanza" |
| rule | "Regla" ✓; consecuencia: "Multa" |
| placeholder actor | "Miembro sin cuenta" (no "placeholder") |
| attention inbox | "Pendientes" (más accionable que "Actividad" para el tab 🔔) |

Regla general: el lenguaje de doctrina (actor, contexto, obligación, novación) jamás
aparece en UI. iOS ya cumple ~90%; falta consistencia, no rediseño.

## 12. Riesgos técnicos

1. **Replay de migraciones**: timestamps duplicados + 221 archivos; un rename mal hecho
   rompe ambientes nuevos. Mitigar con Fase 0 + CI edge-tests (ya existe).
2. **Carrera en ejecución de gobernanza/decisiones**: check de status sin lock; baja
   probabilidad, alto impacto (doble payout). Fase 6/P6.
3. **Divergencia balance**: mientras coexistan ledger incompleto + balance-desde-
   obligations, dos pantallas pueden mostrar números distintos. Fase 2.
4. **pg_cron sin manejo de errores visible** (R.6.C): un detector que truena en silencio
   = multas que no llegan. Agregar logging/alerting.
5. **Crecimiento de god-views**: a 2,000 líneas el type-checker de Swift se degrada y
   cada fix nuevo (la serie R.5Z lo muestra) aterriza ahí. Fase 5.
6. **Tres motores a medias simultáneos**: el riesgo compuesto más alto. Congelar
   alcance nuevo hasta cerrar R.6.G, R.7 fase 1 y R.8.C.
7. **Contrato desactualizado**: cualquier agente/dev que lea MVP2_iOS_Contract.md hoy
   genera código contra un backend de hace 25 RPCs.

## 13. Decisiones arquitectónicas que debes tomar (founder)

1. **Ledger: ¿completar o archivar?** Recomendación: completar (1 migración) y usarlo
   como verificación de integridad; balance canónico de UI sigue siendo obligations.
2. **¿El contexto como parte económica directa?** Hoy: acreedor de multas sí, parte de
   gastos no, custodio de pool no (pool es actor aparte). Recomendación: mantener
   asimetría a propósito y documentarla en doctrina — "el grupo solo posee dinero a
   través de pools explícitos" — que es coherente con tu decisión de pools explícitos.
3. **Guests y dinero**: ¿el invitado pesa en el split de quien lo invitó (simple,
   recomendado para MVP) o se convierte en placeholder con deuda propia? Decidir antes
   de P2.
4. **Atención**: ¿notifications R.4D se congela hasta push real? Recomendación: sí.
5. **Naming UI**: ¿"Grupo" como término default de cara al usuario? (ver §11).
6. **Task primitive**: el doc concluye "primitiva en doctrina, diferida en
   implementación" — ratificar y no abrir hasta que obligations action-kind se quede
   corto en uso real.
7. **Freeze de alcance**: ¿pausa de consolidación de 2 semanas antes de R.9?
   Recomendación fuerte: sí.
