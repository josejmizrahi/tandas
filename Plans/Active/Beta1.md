# Beta 1 — Real-cena observation period

> Status: **active**, freeze arquitectónico **levantado el 2026-05-08**.
> Arrancado 2026-05-07. Las cenas siguen documentándose en § 5 como
> señal cualitativa, pero ya no bloquean Phase 2 — el founder decidió
> arrancar refactor de primitives directo (`Plans/Active/Primitives.md`).
> El propósito original era comportamiento humano sobre correctness
> técnica; ahora corren en paralelo.

---

## 1. Goal

Validar **adopción social**, no estabilidad técnica. La pregunta:

> Cuando 4–6 grupos reales cenan con ruul varias veces, ¿qué hacen,
> qué ignoran, qué resuelven en WhatsApp en lugar de en la app?

Cosas a comprobar:

- ¿Las reglas que el grupo activó se usan o las apagan?
- ¿Las multas se cobran, se waivean, o se ignoran?
- ¿Las apelaciones se votan o "se arregla por WhatsApp"?
- ¿Los recordatorios automatizados ayudan o molestan?
- ¿La transparencia (history, votos públicos) genera confianza o conflicto?
- ¿Aparecen requests de features no previstos?

Solo después de Beta 1 se decide qué primitiva de Fase 2 priorizar:
**Rotation universal**, **Slot/Booking**, **Asset**, **Fund**, o mezcla mínima.

---

## 2. Architecture freeze

> **2026-05-08 — Freeze levantado.** El founder decidió saltar el
> journal-of-cenas como gating de Phase 2 y arrancar refactor de
> primitives según `Plans/Active/Primitives.md`. Trabajo arquitectónico
> nuevo permitido a partir de hoy. Las cenas reales siguen siendo
> señal cualitativa útil pero ya no bloquean nada. Las reglas
> originales abajo se conservan como referencia histórica del intento.

### Original (efectivo 2026-05-07 → 2026-05-08)

A partir del 2026-05-07, **no se mete trabajo estructural nuevo**.

### Permitido durante Beta 1
- Bugs críticos (crashes, corrupción de datos, pérdida de auth).
- Estabilidad (rate limits, retries, recovery).
- Polish UX no-estructural (copy, alineación, typo).
- Analytics mínimos (eventos PostHog para preguntas observables).
- Logging útil (Sentry breadcrumbs, structured logs).

### NO permitido durante Beta 1
- Nuevas primitivas (Slot, Rotation, Asset, Fund, Position).
- Refactors arquitectónicos.
- Templates nuevos.
- Cambios al rule engine (triggers/conditions/consequences).
- Removals que la otra sesión no pidió explícitamente.
- Phase2 work — esperar journal data.

### Excepciones (requieren tu OK explícito)
Si una fricción real recurrente bloquea uso, se evalúa caso por caso.
Pero el default es **anotar el journal y seguir**.

---

## 3. Cena journal template

Una entrada por cena. Plantilla canónica:

```markdown
## Cena #N — YYYY-MM-DD — <Grupo>

**Asistentes**: <lista>
**Anfitrión asignado**: <nombre>
**Reglas activas en el grupo**: <lista de slugs>

### Lo que pasó
- <evento social, no logs técnicos>

### Reglas que se activaron
- <slug — qué pasó — se aplicó / se waiveó / se ignoró>

### Conflictos sociales
- <discusión que generó la app o que la app no resolvió>

### Workarounds
- <cosas que el grupo resolvió fuera de la app — WhatsApp, voz, etc.>

### Notificaciones
- <cuáles llegaron, cuáles ayudaron, cuáles molestaron>
- <cuáles deberían haber llegado y no llegaron>

### Feedback verbal
- <"esto está padre" / "esto sobra" / "qué pena que..." — verbatim si posible>

### Ideas nuevas (no implementar todavía)
- <feature requests orgánicos del grupo>

### Bugs encontrados
- <descripción + repro steps si aplican>

### Observaciones sociales
- <quién lideró, quién resistió, dinámicas de grupo, jerarquías
  implícitas, cosas que la app cambió en el grupo>

### Veredicto del founder
- <una línea: "vale la pena" / "fricción inaceptable" / "neutral">
```

Append al final de [§5 Journal entries](#5-journal-entries).

---

## 4. Observable questions (analytics minimal)

Mínimo viable de telemetría para evitar dependencia 100% del journal
manual. Lo emitido hoy desde iOS — todo via `LogAnalyticsService` →
OSLog `subsystem:com.josejmizrahi.ruul category:analytics`. Pull
durante Beta vía Xcode → Window → Devices and Simulators → View
Device Logs y filtrar.

### Eventos iOS (`Services/Analytics/`)

| Evento | Cuándo se emite | Properties relevantes |
|---|---|---|
| `app_opened` | scenePhase → .active | (ninguna — count signal) |
| `notification_tapped` | tap de push que abre la app | `kind` (event/rule/vote/fine/...) |
| `onboarding_started` / `onboarding_completed` / `onboarding_step_*` | flujo onboarding | `flow_type`, `step_id`, ms |
| `group_created` | tras create_group_with_admin | `has_vocabulary`, `fines_enabled`, `rules_count` |
| `rsvp_changed` | toggle RSVP | `from_status`, `to_status`, `time_to_event_hours` |
| `check_in` | check-in self/manual/QR | `method`, `location_verified` |
| `vote_cast` | tras castRepo.cast() exitoso | `vote_type`, `choice` |
| `fine_seen` | FineDetailView.task `.trackSeen()` | `is_mine`, `status` |
| `fine_appeal_started` | startAppeal() exitoso | `fine_id`, `rule_slug` |
| `fine_paid` | payFine() exitoso | `amount_mxn` |

### Queries SQL complementarias (server-side)

Para preguntas que no necesitan iOS instrumentation, leer directo de Supabase:

| Pregunta | Query |
|---|---|
| ¿Las reglas se usan? | `select rule_id, count(*) from fines group by rule_id` |
| ¿Distribución de status de multas? | `select status, count(*) from fines group by status` |
| ¿Apelaciones casteadas vs abiertas? | `select count(*) filter (where status='resolved') / count(*) from votes where vote_type='fine_appeal'` |
| ¿APNs delivery? | edge function `dispatch-notifications` Sentry breadcrumbs |

### Regla
Implementación de cualquier métrica nueva: **solo si requiere < 1h
de trabajo**. Si requiere refactor (e.g. wirear analytics en otro
coordinator), anotar en `Plans/Active/Beta1Followups.md` (a crear
cuando aparezca el primer item) y diferir.

---

## 5. Journal entries

> Append nuevas cenas abajo. Mantener orden cronológico.

### Cena #0 — placeholder

Aún no hay cenas. Esta sección se llena durante Beta 1.

---

## 6. Exit criteria → decisión Phase 2

Beta 1 se cierra cuando se cumple **una** de:

- 4–6 cenas reales documentadas en §5.
- 2 grupos distintos completaron al menos 2 cenas cada uno.
- Pasaron 6 semanas calendar (lo que cierre primero — evitar perfecto-enemigo-bueno).

**Insumo arquitectónico para esta decisión**: ver
`Plans/Active/Primitives.md` — documento canónico que ubica cada
candidata (Rotation, Slot, Asset, Fund, Booking, Contribution…) en
niveles L1–L5 y aplica la regla de Resource (§5). **No abrir
primitives nuevas sin chequear contra ese doc.** El journal manda
qué; Primitives.md manda dónde encaja.

**Output al cerrar**:

1. Resumen de §5 en sección 7 (abajo).
2. Top 3 fricciones recurrentes.
3. Top 3 features pedidas orgánicamente.
4. Decisión documentada: **¿qué primitiva de Phase 2 prioriza?**
   - Rotation universal (si hosts/turnos fueron el centro del valor)
   - Slot/Booking (si surge demanda de "ese pedazo es mío en X")
   - Asset (si el grupo tiene algo físico/digital que rota)
   - Fund (si pidieron mover dinero de verdad — alta probabilidad
     pero alto riesgo regulatorio, ver Roadmap §3 Fase 3 D3)
   - Mezcla mínima de 2 primitivas.
   - Cualquiera que sea, mapearla contra `Primitives.md` antes de
     diseñar implementación.
5. Crear `Plans/Active/Phase2.md` basado en la decisión + frictions reales.

---

## 7. Beta 1 retrospective

> A llenar al cerrar.

### Top 3 fricciones recurrentes
1. ⏳
2. ⏳
3. ⏳

### Top 3 features pedidas orgánicamente
1. ⏳
2. ⏳
3. ⏳

### Decisión Phase 2

**Estado al 2026-05-08**: no decidida. §5 todavía no contiene cenas
reales documentadas (`Cena #0` es placeholder), así que no hay evidencia
suficiente para elegir primitiva sin sesgar el roadmap.

**Gate de decisión**: cerrar una de las condiciones de §6 y elegir la
primitiva dominante con esta regla:

1. **Rotation universal** si 2+ entradas muestran fricción en turnos,
   anfitrión, orden o rotación.
2. **Slot/Booking** si 2+ entradas piden reservar/asignar un cupo,
   fecha, acceso o "pedazo" específico.
3. **Asset** si 2+ entradas giran alrededor de un objeto, lugar o
   acceso físico/digital compartido.
4. **Fund** si 2+ entradas piden mover, custodiar o auditar dinero
   común. Requiere nota explícita de riesgo regulatorio antes de planear.
5. **Mezcla mínima** solo si dos señales aparecen empatadas y el E2E
   necesita ambas para demostrar valor.

**Siguiente acción**: documentar la primera cena real en §5 dentro de
las 48h posteriores. No crear `Plans/Active/Phase2.md` hasta que este
gate tenga evidencia suficiente.

---

## 8. Anti-objetivos de Beta 1

Cosas que **no** se hacen en Beta 1, aunque el bug-itch tienta:

- No optimizar antes de tiempo. Si una query es lenta pero el grupo
  no la nota, no se toca.
- No agregar primitivas "porque sería fácil". El propósito es saber
  cuál vale la pena, no cuál es fácil.
- No re-pintar la UI con cada cena. La sesión paralela del DS ya
  está iterando v3; las observaciones de Beta 1 alimentan v4 después
  del retrospectivo.
- No expandir el grupo de testers. 4–6 cenas reales > 50 cenas
  superficiales. Si el founder no participa o no observa de cerca,
  no es Beta 1, es noise.
- No publicar en App Store. TestFlight con grupos invitados.

---

## 9. Operación durante Beta 1

- Founder participa **en cada cena** o entrevista al grupo en las 24h
  siguientes mientras la memoria está fresca.
- Cada entrada de journal se escribe en las 48h post-cena. Pasada esa
  ventana, la observación pierde fidelidad — anotar lo que se recuerde
  pero marcar `[memoria parcial]`.
- Bugs críticos se atienden en pull-back-to-V1 mode: solo el bug, sin
  refactor adyacente. Commit small, push fast.
- Si un grupo abandona la app durante Beta 1, **eso es señal**. Anotar
  con la mayor honestidad posible las razones — no es fracaso, es data.

---

## 10. Cómo se relaciona con otros docs

- `Plans/Active/Roadmap.md` — north star de las 6 fases.
- `Plans/Active/Audit-2026-05-06.md` — los 5 items pre-Fase 2 ya
  cerrados (consolidación arquitectónica completa).
- `docs/README.md` — mapa canónico de docs.
- `docs/Ruul-Social-Primitives-and-Product-Logic.md` — referencia para
  interpretar observaciones sociales del journal.
- `Plans/Completed/Phase1.md` — qué shippeó V1 (lo que está en TestFlight
  durante Beta 1).
