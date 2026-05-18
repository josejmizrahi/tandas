# Placeholder Members — Design Spec

- **Date:** 2026-05-17
- **Status:** `blocked-by-freeze` — diseño aprobado en concepto; implementación
  pendiente de exemption explícita del founder respecto al
  Consistency Audit freeze (2026-05-17).
- **Owner:** José Mizrahi (founder)
- **Touches:** L1 `Identity`, L1 `Membership`, `Invite`, projection layer,
  edge functions, iOS app onboarding & group screens.

---

## 1. Summary

Permitir que un admin agregue a alguien a un grupo (nombre + teléfono)
**antes** de que la persona se registre, y que ese miembro ya cuente
para rotaciones, RSVPs, fines, votos, splits y demás. Cuando la persona
real instale Ruul y se autentique por cualquier método (phone OTP, Apple,
Google, email), su identidad se **fusiona** con la del placeholder sin
perder historial y sin violar append-only.

## 2. Problem & motivation

Hoy `group_members.user_id` es `NOT NULL → auth.users(id)`. Para que
alguien "exista" en un grupo, alguien tiene que crear esa cuenta —
o sea, el invitado tiene que aceptar la invitación e instalar la app.

Esto rompe el caso prototípico de Ruul ("cenas con amigos"): el admin
quiere armar el grupo de 8 personas hoy, asignar turnos, y mandarles
WhatsApp para que se vayan sumando. Hoy el grupo no se puede armar
hasta que las 8 acepten — punto de fricción brutal.

## 3. Goals

- Admin puede agregar miembros con (nombre, teléfono) y verlos
  participar de inmediato en rotación, RSVP, fines, votos, splits.
- El real, al registrarse por **cualquier provider** (phone OTP, Apple,
  Google, email link), termina como dueño del historial atribuido al
  placeholder — sin fricción.
- El real puede **rechazar** el historial atribuido si no es suyo
  (privacy / disputa).
- Cero violación de append-only: ningún atom existente se borra ni se
  re-asigna.
- Cero nuevo primitive, resource_type ni capability. Sólo evolución
  de la L1 `Identity` (Supabase ya soporta `is_anonymous`).

## 4. Non-goals

- Placeholders sin teléfono (sólo nombre). Requiere otro mecanismo de
  claim — fuera de scope MVP.
- Placeholders compartidos entre grupos (un Juan en 3 grupos = 3
  placeholders, no 1). Compartirlos requiere identity-resolution
  global y se difiere.
- Email como shared signal (sólo phone en MVP).
- Reasignar atoms históricos al canonical user (los atoms son del
  placeholder uid para siempre; las projections resuelven via
  `identity_resolver`).
- Caducidad automática de placeholders no reclamados.

## 5. Doctrinal classification

Aplicando el formato obligatorio de `[[project-architecture-doctrine]]`
a cada elemento propuesto:

### 5.1. Placeholder `auth.users` row

1. **Clasificación:** Subject (variante "pending identity").
2. **Justificación:** Es un user real en Postgres (FKs lo requieren), pero
   sin titular humano todavía. Supabase ya soporta esta semántica via
   `is_anonymous=true`. No es entidad nueva — es un valor del primitive
   existente `Identity`.
3. **Persistencia:** Sí, persistente. Mutable pre-claim (nombre/phone
   editables por admin). Post-merge, marcado con
   `raw_user_meta_data.merged_into = <canonical_uid>` pero **no se borra**
   (para no romper FKs históricas de atoms).
4. **Ubicación ontológica:** Layer 1 (Subjects). No requiere primitive
   nuevo. Sí requiere nueva projection: `public.identity_resolver`.
5. **Riesgos:** Estado mutable evitable (pre-claim phone/nombre) →
   aceptable porque es metadata de un subject, no truth. No duplica
   verdad — el merge unifica via `identity_resolver`, no por
   reasignación.

### 5.2. `profiles.is_placeholder`, `profiles.claimed_at`

1. **Clasificación:** Configuration/metadata sobre un subject existente.
2. **Justificación:** Banderas operacionales para UI y RPCs; ninguna
   conduct rule depende de su valor (las rules no leen profiles).
3. **Persistencia:** Mutable. `is_placeholder` se setea en creación y se
   limpia en claim; `claimed_at` se setea en claim.
4. **Ubicación:** Layer 1 metadata.
5. **Riesgos:** Si una rule futura las leyera, se volvería truth — guard
   doc: estas columnas son UI-only.

### 5.3. `group_members.joined_via='placeholder'`

1. **Clasificación:** Relation con un valor enum nuevo en columna
   existente.
2. **Justificación:** `joined_via` ya existe (mig 00180) — sólo agrega
   un valor al enum/check.
3. **Persistencia:** Inmutable post-insert (igual que los demás
   `joined_via`).
4. **Ubicación:** Layer 3 (Relations).
5. **Riesgos:** Ninguno.

### 5.4. `invites.placeholder_user_id`, `invites.claim_token_hash`

1. **Clasificación:** Metadata del invite existente.
2. **Justificación:** El invite ya es la entidad que coordina admisión.
   Agregar puntero al placeholder y al token de claim no cambia su
   naturaleza.
3. **Persistencia:** Inmutable post-insert (excepto `used_at`,
   `used_by_user_id` ya existentes).
4. **Ubicación:** Layer 3 metadata (invite es relation User→Group).
5. **Riesgos:** Ninguno.

### 5.5. Nuevos `system_event` types

- `member.placeholder_created` — atom emitido al crear placeholder.
- `member.claimed` — atom emitido en claim/merge exitoso.
- `member.merge_declined` — atom emitido cuando el real rechaza el
  historial.

1. **Clasificación:** Actions (atoms).
2. **Justificación:** Tres hechos del mundo, append-only.
3. **Persistencia:** Append-only via `record_system_event` (SECURITY
   DEFINER, no UPDATE/DELETE).
4. **Ubicación:** Layer 4 (Actions).
5. **Riesgos:** Ninguno (siguen el patrón vigente).

### 5.6. `identity_resolver` view

1. **Clasificación:** Projection.
2. **Justificación:** Vista derivada de `auth.users.raw_user_meta_data`
   que mapea `raw_id → canonical_id`. Recomputable.
3. **Persistencia:** No persiste (es view). Recomputable trivialmente.
4. **Ubicación:** Layer 9 (Projections).
5. **Riesgos:** Si projections existentes la ignoran, mostrarán al
   placeholder como entidad separada del real post-claim — feo pero no
   incorrecto. Mitigación: migración incremental documentada §13.

### 5.7. RPCs nuevas

- `create_placeholder_member(p_group_id, p_display_name, p_phone_e164)` — Action.
- `claim_placeholder_by_token(p_token)` — Action.
- `decline_placeholder_merge(p_token)` — Action.
- `merge_placeholder_into_user(p_placeholder, p_target)` — Action interna
  llamada por las dos anteriores.

Todas SECURITY DEFINER, todas emiten atoms.

### 5.8. Veredicto global

Cero primitive nuevo. Cero resource_type. Cero capability. Cero
módulo. Tres atom types nuevos. Una projection view nueva. Cuatro RPCs.
Dos columnas nuevas en `profiles`, dos en `invites`, un nuevo valor enum
en `group_members.joined_via`.

**El spec es compatible con la doctrina.** Pero **es feature nueva** y
por tanto **incompatible con el freeze actual hasta exemption explícita**
(§17).

## 6. Background — estado actual

- `auth.users`: tabla Supabase estándar. Soporta `is_anonymous=true`.
  Unique constraint en `phone` (cuando no-NULL) y `email` (cuando
  no-NULL).
- `public.profiles`: 1:1 con `auth.users`. Tiene `display_name`,
  `phone`, etc. **No tiene** `is_placeholder` ni `claimed_at` hoy.
- `public.group_members`: `user_id NOT NULL → auth.users(id)`. Tiene
  `joined_via` text (mig 00180, valores actuales: `'self'`, `'invite'`,
  `'admin_add'`). No acepta `'placeholder'` hoy.
- `public.invites`: tiene `id`, `group_id`, `invited_by`, `phone_e164`,
  `used_at`, `used_by_user_id`, `expires_at`. **No tiene**
  `placeholder_user_id` ni `claim_token_hash`.
- WhatsApp envío via edge function `send-whatsapp-invite` (Wassenger,
  best-effort).
- Decenas de tablas tienen `user_id NOT NULL → auth.users(id)` con
  diferentes UNIQUE constraints: `group_members`, `rsvps`, `vote_casts`,
  `expense_shares`, `pot_entries`, `fines.user_id`, `fines.host_user_id`,
  `ledger_entries.subject_user_id`, `system_events.actor_user_id`,
  etc. Algunas tablas son atoms (append-only); otras son projection o
  state mutable.

## 7. Design overview

```
ADMIN agrega placeholder
  ↓
edge fn `create-placeholder-member`
  ├─ check phone NOT in auth.users (real)
  ├─ if exists → respond "user exists, agregar directo?"
  └─ else:
      ├─ auth.admin.createUser({ is_anonymous: true,
      │     user_metadata: { placeholder: true, display_name } })
      ├─ INSERT profiles(id, display_name, phone, is_placeholder=true,
      │     claimed_at=NULL)
      ├─ INSERT group_members(group_id, user_id=placeholder,
      │     joined_via='placeholder', active=true, turn_order=next)
      ├─ INSERT invites(group_id, phone_e164, placeholder_user_id,
      │     claim_token_hash, expires_at=now+30d)
      ├─ record_system_event(member.placeholder_created)
      └─ send-whatsapp-invite with claim_token magic link

PLACEHOLDER PARTICIPA NORMAL
  · cuenta en rotation, RSVP, fines, splits, votos
  · UI muestra badge "Pendiente"
  · admin puede editar nombre/phone o remover hasta el claim

REAL RECLAMA
  ├─ Camino A: tapea magic link en WhatsApp
  │   ├─ deep link → app
  │   ├─ si no autenticado → cualquier provider
  │   └─ claim_placeholder_by_token(token)
  └─ Camino B: post-login phone match (sólo si verificó phone)
      └─ app detecta placeholder con phone = mi auth.users.phone
        → ofrece "Reclamar tu lugar en [grupo]"
        → user pulsa → claim_placeholder_by_token(token)

CLAIM ejecuta:
  ├─ verify token + actor
  ├─ MOSTRAR resumen del historial al real
  ├─ user elige:
  │   ├─ Aceptar → merge_placeholder_into_user(placeholder, target)
  │   └─ Rechazar → decline_placeholder_merge(token)
  └─ record_system_event(member.claimed | member.merge_declined)

MERGE engine:
  ├─ marca auth.users[placeholder].user_metadata.merged_into = target
  ├─ reasigna FKs en tablas mutables (whitelist):
  │   · group_members, profiles, notification_tokens,
  │     notification_preferences, otp_codes pendientes
  ├─ NO toca tablas append-only (system_events, vote_casts,
  │   ledger_entries, atoms_*) — la identidad histórica vive
  │   resuelta via `identity_resolver` view
  └─ borra placeholder profiles row (canonical sigue siendo target)
```

## 8. Identity model

### 8.1. Placeholder `auth.users` row

- `is_anonymous = true`
- `phone = NULL` — **clave**: no ocupamos el phone en auth.users para
  que el real pueda autenticarse por phone OTP sin choque
- `email = NULL`
- `raw_user_meta_data = { placeholder: true, display_name: 'Juan' }`
- Creado vía Supabase Admin API (`auth.admin.createUser`) desde edge
  function con service role.

### 8.2. Placeholder `profiles` row

- `id = placeholder_uid`
- `display_name = 'Juan'`
- `phone = '+52555...'` — sólo aquí (en profiles, no en auth.users)
- `is_placeholder = true` (col nueva)
- `claimed_at = NULL` (col nueva)
- `claimed_by_user_id = NULL` (col nueva) — set en claim, apunta a target

### 8.3. Post-merge state

- `auth.users[placeholder]` permanece, con
  `raw_user_meta_data.merged_into = target_uid`.
- `profiles[placeholder]` **se borra** (canonical sigue siendo
  `profiles[target]`).
- Todos los atoms históricos (`system_events`, `vote_casts`,
  `ledger_entries`, etc.) siguen apuntando a `placeholder_uid`.
- Vista `identity_resolver` mapea `placeholder_uid → target_uid`.
- Projections que pasan por `identity_resolver` ven al canonical.

### 8.4. `identity_resolver` view

```sql
create or replace view public.identity_resolver as
with recursive resolver as (
  select
    u.id as raw_id,
    coalesce((u.raw_user_meta_data->>'merged_into')::uuid, u.id)
      as next_id,
    0 as depth
  from auth.users u
  union all
  select
    r.raw_id,
    coalesce((u.raw_user_meta_data->>'merged_into')::uuid, u.id)
      as next_id,
    r.depth + 1
  from resolver r
  join auth.users u on u.id = r.next_id
  where r.depth < 10
    and (u.raw_user_meta_data->>'merged_into') is not null
)
select
  raw_id,
  next_id as canonical_id
from resolver
where (
  select coalesce((u2.raw_user_meta_data->>'merged_into')::uuid, u2.id)
  from auth.users u2 where u2.id = resolver.next_id
) = resolver.next_id;  -- fixpoint
```

Garantiza terminación con `depth < 10`. Defensa contra ciclos
(no debería ocurrir; el merge no crea ciclos por construcción).

`grant select on public.identity_resolver to authenticated`.

## 9. Creation flow

### 9.1. Edge function `create-placeholder-member`

Service role. Input: `{ group_id, display_name, phone_e164 }`.

```typescript
export async function handler(req) {
  const { group_id, display_name, phone_e164 } = await req.json();
  const actor = await getAuthUser(req);

  // 1. permission check
  const canInvite = await supabase.rpc('has_permission', {
    p_group_id: group_id,
    p_user_id: actor.id,
    p_permission: 'members.invite',
  });
  if (!canInvite.data) return 403;

  // 2. phone normalize + validate
  const phone = normalizePhone(phone_e164);
  if (!isE164(phone)) return 400;

  // 3. duplicate-phone check (real users only)
  const { data: existing } = await supabase.auth.admin
    .listUsers({ filter: `phone.eq.${phone}` });
  if (existing?.users?.length > 0) {
    // No crear placeholder — devolver hint al cliente para que ofrezca
    // "agregar directo" via add_existing_member RPC
    return Response.json({
      kind: 'existing_user',
      user_id: existing.users[0].id,
      display_name: existing.users[0].user_metadata?.display_name,
    }, { status: 409 });
  }

  // 4. dup placeholder check
  const { data: dupPlaceholder } = await supabase
    .from('profiles')
    .select('id')
    .eq('phone', phone)
    .eq('is_placeholder', true)
    .is('claimed_at', null)
    .maybeSingle();
  if (dupPlaceholder) {
    return Response.json({
      kind: 'duplicate_placeholder',
      user_id: dupPlaceholder.id,
    }, { status: 409 });
  }

  // 5. create placeholder auth user
  const { data: placeholderUser, error: createErr } = await supabase
    .auth.admin.createUser({
      email_confirm: false,
      user_metadata: {
        placeholder: true,
        display_name,
        created_by: actor.id,
      },
    });
  if (createErr) return 500;
  const placeholderUid = placeholderUser.user.id;
  // Mark as anonymous explicitly — Supabase Admin API doesn't expose
  // is_anonymous directly; we set it via raw_user_meta_data flag and
  // a DB trigger/RPC nudges auth.users.is_anonymous=true if needed.

  // 6. insert profile + group_members + invite in a single RPC
  const { data: result, error: rpcErr } = await supabase.rpc(
    'finalize_placeholder_member', {
      p_placeholder_user_id: placeholderUid,
      p_group_id: group_id,
      p_display_name: display_name,
      p_phone_e164: phone,
      p_actor_user_id: actor.id,
    },
  );
  if (rpcErr) {
    // Rollback orphan auth user
    await supabase.auth.admin.deleteUser(placeholderUid);
    return 500;
  }

  // 7. send WhatsApp magic link (best-effort)
  await sendWhatsAppClaim(phone, group_id, result.claim_token);

  return Response.json({
    kind: 'created',
    member: result.member,
    invite_id: result.invite_id,
  });
}
```

### 9.2. RPC `finalize_placeholder_member`

SECURITY DEFINER, atómica:

```sql
create function public.finalize_placeholder_member(
  p_placeholder_user_id uuid,
  p_group_id uuid,
  p_display_name text,
  p_phone_e164 text,
  p_actor_user_id uuid
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_claim_token text := encode(gen_random_bytes(32), 'hex');
  v_claim_token_hash text := encode(
    digest(v_claim_token, 'sha256'), 'hex'
  );
  v_invite_id uuid;
  v_turn int;
begin
  -- permission re-check (defense in depth)
  if not public.has_permission(p_group_id, p_actor_user_id,
                               'members.invite') then
    raise exception 'forbidden';
  end if;

  -- insert profile
  insert into public.profiles
    (id, display_name, phone, is_placeholder, claimed_at)
  values
    (p_placeholder_user_id, p_display_name, p_phone_e164, true, null);

  -- compute next turn_order
  select coalesce(max(turn_order), 0) + 1 into v_turn
  from public.group_members where group_id = p_group_id;

  -- insert membership
  insert into public.group_members
    (group_id, user_id, role, turn_order, joined_via, active)
  values
    (p_group_id, p_placeholder_user_id, 'member', v_turn,
     'placeholder', true);

  -- insert invite with claim token
  insert into public.invites
    (group_id, invited_by, phone_e164, claim_token_hash,
     placeholder_user_id, expires_at)
  values
    (p_group_id, p_actor_user_id, p_phone_e164, v_claim_token_hash,
     p_placeholder_user_id, now() + interval '30 days')
  returning id into v_invite_id;

  -- emit atom
  perform public.record_system_event(
    p_event_type := 'member.placeholder_created',
    p_group_id   := p_group_id,
    p_actor      := p_actor_user_id,
    p_payload    := jsonb_build_object(
      'placeholder_user_id', p_placeholder_user_id,
      'invite_id', v_invite_id,
      'phone_e164', p_phone_e164,
      'display_name', p_display_name
    )
  );

  return jsonb_build_object(
    'claim_token', v_claim_token,    -- raw, only returned to creator
    'invite_id', v_invite_id,
    'member', jsonb_build_object(
      'user_id', p_placeholder_user_id,
      'group_id', p_group_id,
      'turn_order', v_turn
    )
  );
end$$;
```

## 10. Communication — WhatsApp + magic link

- El edge function `send-whatsapp-invite` extiende su payload para
  aceptar `claim_token`. Si está presente, manda copy:

  > "Hola! [Admin] te agregó al grupo *[Grupo]* en Ruul.
  > Tu lugar ya está reservado — activa tu cuenta:
  > https://ruul.app/claim/[token]"

- Universal link iOS apunta a `/claim/<token>` → handler en
  `Tandas/Shell` detecta y navega a `ClaimPlaceholderView`.

- Si el real no tiene la app: el link cae en fallback web que
  redirige a App Store + preserva el token via deep link
  (Branch.io / Universal Links con deferred handling — se decide en
  implementación).

## 11. Claim flow

### 11.1. Camino A — magic link

```
WhatsApp tap → universal link /claim/<token> → app
  ├─ if not signed in:
  │   show auth picker (phone OTP / Apple / Google / email)
  │   wait for sign in
  └─ call rpc claim_placeholder_by_token(token)
      ├─ returns { placeholder_uid, group, history_summary }
      ├─ app shows ClaimReviewView with summary
      ├─ user taps "Aceptar" or "Rechazar"
      └─ call accept_placeholder_claim(token)
         or decline_placeholder_claim(token)
```

### 11.2. Camino B — phone match post-login

Después de cualquier sign-in donde el user tiene `auth.users.phone`
verificado:

```
post-login bootstrap (AppState.refreshSession)
  ├─ call discover_pending_placeholders()
  │   returns [{ placeholder_uid, group, claim_token, ... }]
  ├─ if any → show PendingClaimsView in onboarding flow
  └─ user per-item: tap → accept_placeholder_claim(token)
```

`discover_pending_placeholders` SECURITY DEFINER:

```sql
create function public.discover_pending_placeholders()
returns table (
  placeholder_uid uuid,
  group_id uuid,
  group_name text,
  display_name text,
  claim_token_hash text  -- so client doesn't need raw token
)
language sql security definer set search_path = public
as $$
  select
    p.id, g.id, g.name, p.display_name, i.claim_token_hash
  from auth.users me
  join public.profiles me_prof on me_prof.id = me.id
  join public.profiles p
    on p.phone = me_prof.phone
    and p.is_placeholder = true
    and p.claimed_at is null
  join public.invites i
    on i.placeholder_user_id = p.id
    and i.used_at is null
    and i.expires_at > now()
  join public.groups g on g.id = i.group_id
  where me.id = auth.uid()
    and me_prof.phone is not null;
$$;
```

Cuando se descubre por phone match, el client llama
`accept_placeholder_claim(p_placeholder_uid := <uid>)` (sin token).
El SQL verifica que `auth.uid()` tiene `phone` que matchea
`profiles[placeholder].phone` — ver §11.4.

### 11.3. Review summary

Antes del accept, el client llama
`get_placeholder_history_summary(placeholder_uid)` que retorna:

- counts: fines pendientes, fines pagados, RSVPs, votos emitidos,
  turnos asignados, contribuciones a fund
- last activity timestamp
- grupos involucrados (siempre 1 en MVP — un placeholder por grupo)

El user ve esto y decide. Privacy first.

### 11.4. RPC `accept_placeholder_claim`

```sql
create function public.accept_placeholder_claim(
  p_claim_token text default null,
  p_placeholder_uid uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_phone text;
  v_placeholder uuid;
  v_invite record;
begin
  if v_actor is null then raise exception 'not authenticated'; end if;

  if p_claim_token is not null then
    -- Camino A: token
    select * into v_invite
    from public.invites
    where claim_token_hash = encode(digest(p_claim_token, 'sha256'), 'hex')
      and used_at is null
      and expires_at > now()
      and placeholder_user_id is not null
    for update;
    if v_invite is null then raise exception 'invalid_token'; end if;
    v_placeholder := v_invite.placeholder_user_id;

  elsif p_placeholder_uid is not null then
    -- Camino B: phone match
    select phone into v_actor_phone
    from auth.users where id = v_actor;
    if v_actor_phone is null then raise exception 'no_verified_phone'; end if;

    if not exists (
      select 1 from public.profiles
      where id = p_placeholder_uid
        and is_placeholder = true
        and claimed_at is null
        and phone = v_actor_phone
    ) then raise exception 'no_match'; end if;
    v_placeholder := p_placeholder_uid;

    -- mark invite used (find the one tied to this placeholder)
    update public.invites
      set used_at = now(), used_by_user_id = v_actor
      where placeholder_user_id = v_placeholder
        and used_at is null;

  else raise exception 'token_or_uid_required'; end if;

  -- advisory lock to serialize concurrent claims on same placeholder
  perform pg_advisory_xact_lock(hashtext(v_placeholder::text));

  -- merge
  perform public.merge_placeholder_into_user(v_placeholder, v_actor);

  -- mark invite used (camino A)
  if p_claim_token is not null then
    update public.invites
      set used_at = now(), used_by_user_id = v_actor
      where id = v_invite.id;
  end if;

  -- emit atom
  perform public.record_system_event(
    p_event_type := 'member.claimed',
    p_group_id   := v_invite.group_id,
    p_actor      := v_actor,
    p_payload    := jsonb_build_object(
      'placeholder_user_id', v_placeholder,
      'canonical_user_id', v_actor
    )
  );

  return jsonb_build_object('canonical_user_id', v_actor);
end$$;
```

## 12. Identity merge engine

`merge_placeholder_into_user(p_placeholder uuid, p_target uuid)`
es la función crítica. SECURITY DEFINER. Llamada sólo desde
`accept_placeholder_claim`.

### 12.1. Algoritmo

```
1. assert p_placeholder != p_target
2. assert p_placeholder profile has is_placeholder=true and claimed_at IS NULL
3. assert p_target is non-anonymous
4. mark auth.users[p_placeholder].raw_user_meta_data.merged_into = p_target
5. reassign FKs in MUTABLE whitelist tables (with conflict resolution)
6. delete profiles[p_placeholder]  -- canonical sigue siendo target
7. (do NOT touch atoms / append-only tables)
```

### 12.2. Whitelist de tablas mutables a reasignar

| Tabla | Política de conflicto |
|---|---|
| `group_members` | Si target ya está en (group_id, target): copiar `turn_order` placeholder al target si target.turn_order IS NULL; copiar `roles` (merge jsonb); delete placeholder row. Else: UPDATE user_id. |
| `profiles` | DELETE placeholder row (target ya tiene su profile canonical). |
| `notification_tokens` | UPDATE user_id; UNIQUE conflicts → DELETE placeholder rows. |
| `notification_preferences` | UPDATE user_id; UNIQUE conflicts → keep target row, DELETE placeholder. |
| `auth.identities` (Supabase) | N/A — placeholder no tiene identity rows. |

Tablas que **NO se tocan** (append-only / atoms):

- `system_events` (atoms — sagrados)
- `vote_casts` (append-only mig 00163)
- `ledger_entries` (atoms — money truth)
- `atom_*` (cualquier tabla con prefix `atom_`)
- `rsvps` — **revisar**: si rsvps es atom-of-record o projection
  mutable. Doctrina dice "RSVP es action" → atom → NO tocar.
- `user_actions` (append-only)
- `fines` — projection sobre ledger; user_id se mantiene apuntando al
  placeholder; vista `fines_view` resuelve via `identity_resolver`.

### 12.3. Implementación

```sql
create function public.merge_placeholder_into_user(
  p_placeholder uuid,
  p_target uuid
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_meta jsonb;
begin
  if p_placeholder = p_target then return; end if;

  if not exists (
    select 1 from public.profiles
    where id = p_placeholder and is_placeholder = true
      and claimed_at is null
  ) then raise exception 'not_a_placeholder %', p_placeholder; end if;

  if exists (
    select 1 from auth.users where id = p_target and is_anonymous = true
  ) then raise exception 'target_must_be_real'; end if;

  -- 1. mark merged_into
  select raw_user_meta_data into v_meta from auth.users where id = p_placeholder;
  update auth.users
    set raw_user_meta_data = coalesce(v_meta, '{}'::jsonb)
      || jsonb_build_object('merged_into', p_target::text)
    where id = p_placeholder;

  -- 2. group_members merge
  perform public._merge_group_members(p_placeholder, p_target);

  -- 3. notification_tokens
  delete from public.notification_tokens
    where user_id = p_placeholder
      and exists (
        select 1 from public.notification_tokens t2
        where t2.user_id = p_target and t2.token = notification_tokens.token
      );
  update public.notification_tokens set user_id = p_target
    where user_id = p_placeholder;

  -- 4. notification_preferences
  delete from public.notification_preferences
    where user_id = p_placeholder;  -- target keeps its own

  -- 5. set claimed_at on target profile (audit), then delete placeholder profile
  update public.profiles
    set claimed_at = now(), claimed_by_user_id = p_target
    where id = p_placeholder;
  delete from public.profiles where id = p_placeholder;

  -- NOTE: atoms (system_events, vote_casts, ledger_entries) intentionally
  -- not modified. identity_resolver view handles the projection layer.
end$$;
```

`_merge_group_members` es helper privado:

```sql
create function public._merge_group_members(
  p_placeholder uuid,
  p_target uuid
) returns void
language plpgsql as $$
declare
  r record;
begin
  for r in
    select gm_p.* from public.group_members gm_p
    where gm_p.user_id = p_placeholder
  loop
    if exists (
      select 1 from public.group_members
      where group_id = r.group_id and user_id = p_target
    ) then
      -- conflict: target already a member of this group
      update public.group_members
        set
          turn_order = coalesce(turn_order, r.turn_order),
          roles = coalesce(roles, '[]'::jsonb)
                  || coalesce(r.roles, '[]'::jsonb),
          active = active or r.active
        where group_id = r.group_id and user_id = p_target;
      delete from public.group_members
        where group_id = r.group_id and user_id = p_placeholder;
    else
      update public.group_members
        set user_id = p_target
        where group_id = r.group_id and user_id = p_placeholder;
    end if;
  end loop;
end$$;
```

### 12.4. Por qué dynamic SQL fue rechazado

Consideré reasignar TODAS las FKs via `information_schema`. Lo
rechacé porque:

1. Mezcla atoms (que NO se deben modificar) con projections (que sí).
   Distinguirlos requiere whitelist explícita → ya estamos hardcoding.
2. Conflict policies son por tabla — no es "un UPDATE genérico".
3. Schema drift futuro: cuando se agregue una tabla nueva, el dev
   tiene que decidir conscientemente si entra en merge — esto es
   bueno, no malo. La whitelist explícita fuerza la decisión.

Trade-off: cuando agreguen una tabla mutable que olviden incluir en
`merge_placeholder_into_user`, queda data huérfana apuntando al
placeholder. Mitigación: test de invariante post-merge (§16) que
verifica que **ninguna tabla mutable whitelisted** tenga rows con
user_id = placeholder.

### 12.5. Projections existentes a migrar

Lista priorizada (migración incremental, tracked como subtasks):

**P0 (Beta-blocking):**
- `member_list_view` (si existe) o equivalente que arma roster del grupo
- `balance_view` / `who_owes_whom_view`
- `fines_view`
- `rotation_state_view` (si existe) o helper que decide próximo host

**P1 (post-Beta):**
- `system_events_view` (para audit log UI)
- `vote_results_view`
- `activity_feed_view`

Para cada projection: agregar JOIN con `identity_resolver` y
agrupar por `canonical_id`. La membresía vigente (`group_members`)
ya está reasignada, así que **el roster de un grupo** muestra al
canonical sin necesidad de identity_resolver — sólo el historial
profundo lo necesita.

## 13. UX & permissions

### 13.1. Permisos

- `create_placeholder_member` requiere permiso
  `members.invite` (mismo que crear invites hoy).
- Editar nombre/phone de placeholder mientras `claimed_at IS NULL`:
  `members.invite`.
- Remover placeholder: `members.remove` (igual que remover miembro).
- Reclamar: cualquier `auth.uid()` con token válido o phone match.
- Rechazar reclamo: igual.

> **Nota de implementación:** los nombres exactos de los permisos
> (`members.invite`, `members.remove`) deben verificarse contra el
> catálogo actual en `groups.roles` jsonb (mig 00063). Si el sistema
> usa otros slugs, se mapea sin cambio de diseño. Mismo cuidado con
> el shape de `notifications_outbox` referenciado en §14 — usar el
> shape vigente al momento de implementar.

### 13.2. UI iOS

- **Group screen → "Agregar miembro" sheet:**
  - Input: nombre (required), teléfono E.164 (required).
  - Validación cliente: phone format.
  - Submit → llama edge function.
  - Casos de respuesta:
    - `created` → toast "Juan agregado. Le mandamos un WhatsApp."
    - `existing_user` → modal "Este número ya es usuario de Ruul como Mariana. ¿Lo agrego directo al grupo?"
    - `duplicate_placeholder` → modal "Ya hay un miembro pendiente con ese número."

- **Member list:**
  - Placeholder con badge "Pendiente" + ícono distinto.
  - Long-press / context menu: "Editar", "Reenviar invite", "Remover".

- **Onboarding del real (post-login):**
  - Si `discover_pending_placeholders` retorna rows, mostrar
    `PendingClaimsView` con cards por grupo:
    - "[Admin] te agregó a *[Grupo]* el [fecha]."
    - "Tu historial pendiente: [counts]."
    - Botones: "Aceptar y entrar", "Revisar antes", "No soy yo".

- **Deep link `/claim/<token>`:**
  - Si no signed in → AuthPicker (con providers actuales).
  - Si signed in → `ClaimReviewView` con summary.

### 13.3. Copy del WhatsApp

```
Hola! José te agregó al grupo *Cena martes* en Ruul. 🎉
Tu lugar ya está reservado.

Para activar tu cuenta y ver el grupo:
https://ruul.app/claim/abc123

Si no instalaste Ruul, este link te lleva a la tienda y
guarda tu invitación.

(Si no esperabas esto, ignora el mensaje.)
```

## 14. Decline merge flow

Si el real revisa el summary y dice "no soy yo / no acepto":

```sql
create function public.decline_placeholder_claim(
  p_claim_token text
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_invite record;
begin
  if v_actor is null then raise exception 'not_authenticated'; end if;
  select * into v_invite
  from public.invites
  where claim_token_hash = encode(digest(p_claim_token, 'sha256'), 'hex')
    and used_at is null
    and expires_at > now()
  for update;
  if v_invite is null then raise exception 'invalid_token'; end if;

  -- 1. mark placeholder as disputed (NOT claimed, NOT deleted)
  update public.profiles
    set is_placeholder = true,
        claimed_at = null,
        claimed_by_user_id = null,
        -- new col: disputed_at + disputed_by
        disputed_at = now(),
        disputed_by_user_id = v_actor
    where id = v_invite.placeholder_user_id;

  -- 2. deactivate placeholder membership (preserve history)
  update public.group_members
    set active = false
    where user_id = v_invite.placeholder_user_id
      and group_id = v_invite.group_id;

  -- 3. burn token
  update public.invites
    set used_at = now(), used_by_user_id = v_actor
    where id = v_invite.id;

  -- 4. emit atom
  perform public.record_system_event(
    p_event_type := 'member.merge_declined',
    p_group_id   := v_invite.group_id,
    p_actor      := v_actor,
    p_payload    := jsonb_build_object(
      'placeholder_user_id', v_invite.placeholder_user_id,
      'reason', 'declined_by_real_owner'
    )
  );

  -- 5. notify admin (creates a notif outbox row)
  insert into public.notifications_outbox
    (recipient_user_id, kind, payload)
  values (
    v_invite.invited_by,
    'placeholder_disputed',
    jsonb_build_object(
      'placeholder_user_id', v_invite.placeholder_user_id,
      'group_id', v_invite.group_id,
      'disputed_by', v_actor
    )
  );
end$$;
```

**Importante:** el placeholder queda `disputed` y `active=false` pero
NO se borra. Admin tiene que reconciliar (re-asignar fines, ajustar
rotación, etc.) manualmente. UI muestra al admin un alert con call to
action.

## 15. Data model changes (migrations)

### 15.1. Migración M1: `profiles` columns

```sql
alter table public.profiles
  add column if not exists is_placeholder boolean not null default false,
  add column if not exists claimed_at timestamptz,
  add column if not exists claimed_by_user_id uuid
    references auth.users(id) on delete set null,
  add column if not exists disputed_at timestamptz,
  add column if not exists disputed_by_user_id uuid
    references auth.users(id) on delete set null;

create unique index profiles_placeholder_phone_uq
  on public.profiles (phone)
  where is_placeholder = true and claimed_at is null;
```

### 15.2. Migración M2: `invites` columns

```sql
alter table public.invites
  add column if not exists placeholder_user_id uuid
    references auth.users(id) on delete cascade,
  add column if not exists claim_token_hash text;

create unique index invites_claim_token_hash_uq
  on public.invites (claim_token_hash)
  where claim_token_hash is not null;

create index invites_placeholder_uid_idx
  on public.invites (placeholder_user_id)
  where placeholder_user_id is not null and used_at is null;
```

### 15.3. Migración M3: `group_members.joined_via` allow `'placeholder'`

Si hay CHECK constraint:

```sql
alter table public.group_members
  drop constraint if exists group_members_joined_via_check;

alter table public.group_members
  add constraint group_members_joined_via_check
  check (joined_via in ('self','invite','admin_add','placeholder'));
```

### 15.4. Migración M4: `identity_resolver` view (§8.4)

### 15.5. Migración M5: RPCs nuevas

`finalize_placeholder_member`, `accept_placeholder_claim`,
`decline_placeholder_claim`, `discover_pending_placeholders`,
`get_placeholder_history_summary`, `merge_placeholder_into_user`,
`_merge_group_members`.

### 15.6. Migración M6: `record_system_event` allow new types

Si el switch/check de `event_type` está hardcoded en
`record_system_event` (mig 00094 group_membership_guard, etc.),
añadir los 3 nuevos types a la whitelist:
`member.placeholder_created`, `member.claimed`, `member.merge_declined`.

### 15.7. Migración M7: RLS sobre profiles

Verificar que SELECT policy de `profiles` no expone phone de
placeholders a non-admins del grupo del placeholder. Probablemente:

```sql
drop policy if exists profiles_select_placeholder on public.profiles;
create policy profiles_select_placeholder on public.profiles
  for select using (
    is_placeholder = false
    or claimed_at is not null
    or auth.uid() = id
    or exists (
      select 1 from public.group_members gm
      where gm.user_id = profiles.id  -- el placeholder es miembro
        and public.is_group_admin(gm.group_id, auth.uid())
    )
  );
```

## 16. Telemetry & invariants

### 16.1. Atoms emitidos

- `member.placeholder_created` con `{ placeholder_user_id, invite_id, phone_e164, display_name }`
- `member.claimed` con `{ placeholder_user_id, canonical_user_id }`
- `member.merge_declined` con `{ placeholder_user_id, reason }`

### 16.2. Invariantes post-merge

Test SQL en CI:

```sql
-- ningún placeholder merged debe quedar con FKs activas en tablas mutables
-- (post-merge el profiles row se borra; el auth.users queda con
--  raw_user_meta_data.merged_into = canonical_uid).
with merged as (
  select id
  from auth.users
  where raw_user_meta_data ? 'merged_into'
)
select 'group_members'::text as tbl, count(*) from public.group_members
  where user_id in (select id from merged)
union all
select 'notification_tokens', count(*) from public.notification_tokens
  where user_id in (select id from merged)
union all
select 'profiles', count(*) from public.profiles
  where id in (select id from merged);
-- expected: all zero (atoms tables intentionally excluded)
```

### 16.3. Métricas dashboard

- # placeholders activos por grupo
- # placeholders reclamados / mes
- tiempo medio creación → claim
- # declined
- # duplicate_phone_blocked

## 17. Risks & mitigations

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Phone re-asignado (años después, otro humano tiene ese número) reclama placeholder ajeno | Alto | Magic link es secret-bearer — sin tap del link no reclama. Phone match secundario requiere phone verificado vía OTP, pero el admin debió tener confianza al digitar el número. Si admin agregó número equivocado, el real puede `decline` y queda audited. |
| R2 | Admin atribuye fines a teléfono ajeno (ataque privacy) | Alto | (a) WhatsApp inicial notifica al dueño del número. (b) Decline preserva historial pero deactiva membresía y notifica admin. (c) Auditoría: atom `member.placeholder_created` queda con `created_by`. |
| R3 | Merge race (dos taps simultáneos) | Medio | `pg_advisory_xact_lock(hashtext(placeholder::text))` en accept. |
| R4 | Placeholder huérfano permanente (nunca reclamado) | Bajo | Admin puede remover. No auto-archive en MVP. Métrica en dashboard. |
| R5 | Schema drift — nueva tabla mutable se olvida en merge whitelist | Medio | Invariante SQL (§16.2) en CI. Code review checklist menciona "¿new user_id col? → revisar merge_placeholder_into_user". |
| R6 | identity_resolver no usado en projection nueva → user post-merge se ve fragmentado | Medio | Lint rule / code review checklist. Documentar como pattern obligatorio en `CLAUDE.md`. |
| R7 | Supabase Admin API limits / cuotas al crear users masivos | Bajo | Rate-limit en edge function (10/min por admin). |
| R8 | Pre-claim `profiles.phone` queryable revela teléfono de placeholder a otros miembros | Medio | RLS en §15.7. |
| R9 | Universal link no abre app (user no la tiene) → fallback a App Store sin preservar token | Medio | iOS Universal Links + Branch.io deferred deep link, o requerir Web → App Store landing que pasa token via clipboard / referrer. Decisión en implementación. |
| R10 | Atoms históricos del placeholder no aparecen en "mi actividad" del real porque la query no usa `identity_resolver` | Bajo (feature de polish) | Subtask P1 de §12.5. |

## 18. Rollout & freeze status

### 18.1. Freeze impact

Esta spec **es una feature nueva** y por lo tanto **incompatible con el
freeze del 2026-05-17** mientras los 12 fixes doctrinales no estén
cerrados (sprints 1-4 de Money/Lifecycle, Rights, Slot, Rule Engine
idempotency).

### 18.2. Opciones

- **(a) Diferida (recomendado):** spec commiteado, status
  `blocked-by-freeze`. Se inicia implementación cuando el freeze se
  levante. Reduce riesgo de regresión en el audit.
- **(b) Exemption explícita del founder:** si la fricción de no poder
  agregar miembros es bloqueante para Beta-1 user testing, el founder
  puede autorizar implementación paralela. La spec no toca ninguno de
  los 12 findings → no compite con el sprint actual. Pero sí extiende
  superficie nueva, lo cual el freeze prohíbe por principio.

Recomiendo (a). Si vamos por (b), agregar un sub-issue de
"Freeze exemption acknowledgement" firmado por el founder antes de
implementar.

### 18.3. Implementación (cuando se desbloquee)

Phases sugeridas para el plan de implementación:

- **Phase 1 — backend foundation:** migraciones M1-M7, RPCs,
  invariante CI, tests unitarios pgTAP.
- **Phase 2 — edge function & WhatsApp:** `create-placeholder-member`,
  extensión de `send-whatsapp-invite`.
- **Phase 3 — iOS UI:** AddMemberSheet expansion, MemberList badges,
  ClaimReviewView, PendingClaimsView, deep link wiring.
- **Phase 4 — projection migration P0:** member_list, balance, fines,
  rotation views usando identity_resolver.
- **Phase 5 — observability:** dashboard metrics, alerting on
  invariant violations.
- **Phase 6 — projection migration P1 (post-Beta):** activity feed,
  audit log, vote results.

## 19. Open questions

Estas se resuelven en implementación o en el plan de detalle:

- **OQ1:** ¿Universal link iOS sin Branch (sólo Apple Universal
  Links + Smart App Banner)? Vs Branch.io para deferred deep link
  robusto. Trade-off costo vs UX si user no tiene la app.
- **OQ2:** Mientras está disputed, ¿el admin puede "reclamarlo a
  nombre de otro miembro existente"? Útil si "ah, era de Pedro, no
  de Juan — reasigna su historial". Útil pero suma superficie.
  Probable: post-MVP.
- **OQ3:** ¿Email como shared signal adicional al phone? Aumenta
  cobertura para Apple Sign-In (que entrega email). Trade-off
  privacy (email de Apple es proxy). Probable: post-MVP.
- **OQ4:** ¿`record_system_event` para `member.placeholder_created`
  cuenta como "membership lifecycle event" del guard mig 00094? Sí
  conceptualmente, pero el guard de hoy probablemente sólo permite
  ciertos tipos — necesita extenderse.
- **OQ5:** Política exacta de qué pasa cuando hay 3+ placeholders
  con el mismo phone (multi-grupo) — el unique partial index lo
  impide a nivel SQL. ¿Queremos permitir que un mismo phone tenga
  un placeholder en grupo A y otro en grupo B simultáneamente, y
  que el claim merge ambos al canonical? Eso flexibilizaría el
  index a `unique(group_id, phone) where is_placeholder=true and
  claimed_at is null`. Probable: sí, esta versión es mejor.

## 20. Out of scope (futuro)

- Placeholders sin teléfono (sólo nombre + claim manual por admin).
- Placeholders compartidos entre grupos (1 identity por persona pre-claim).
- Auto-caducidad / archive de placeholders viejos.
- Self-service: invitee sin teléfono recibe link genérico por copy/paste
  (sin WhatsApp).
- AI sugiriendo "este placeholder se parece a Pedro existente, ¿merge?".

## 21. Relación con doctrina

- `[[project-architecture-doctrine]]` — clasificación aplicada §5.
- `[[project-ontology-constitution]]` — sin nuevos primitives.
- `[[project-consistency-audit-freeze]]` — esta spec respeta la
  declaración del freeze (status `blocked-by-freeze`).
- `[[project-rules-hierarchy]]` — N/A.
- `[[project-group-governance-rules]]` — el permiso `members.invite`
  se reutiliza tal cual.
- `[[feedback-no-hardcoded-verticals]]` — universal a cualquier
  grupo / template.

---

_End of design spec._
