-- 20260529210833: V3-INV fix — group_memberships.user_id NULLABLE for
-- placeholder claims.
--
-- Founder hit "null value in column user_id violates not-null constraint"
-- when inviting a phone number that doesn't yet have a profile. V3-R0
-- spawns a placeholder membership with `user_id = NULL` so the invitee
-- can be a payer/participant before they accept; the existing NOT NULL
-- constraint blocks that flow.
--
-- accept_invite already reconciles by setting user_id = auth.uid()
-- when the invitee redeems the code, so the NULL is transient.
--
-- Adds a CHECK invariant: user_id may only be NULL when joined_via =
-- 'placeholder_claim'. That keeps the rest of the schema honest (no
-- active member without a user_id).

ALTER TABLE public.group_memberships
  ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE public.group_memberships
  ADD CONSTRAINT group_memberships_user_id_required_unless_placeholder
  CHECK (user_id IS NOT NULL OR joined_via = 'placeholder_claim');

COMMENT ON COLUMN public.group_memberships.user_id IS
  'auth.users id. NULL is permitted only for V3-R0 placeholder rows (joined_via=placeholder_claim); accept_invite reconciles by setting the value on redeem.';
