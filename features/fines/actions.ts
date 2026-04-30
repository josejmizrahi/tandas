'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import {
  PayFineSchema,
  IssueManualFineSchema,
  OpenFineAppealSchema,
} from './schemas'

export type ActionResult = { ok: true } | { error: { _form?: string[]; [k: string]: string[] | undefined } }

export async function payFine(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = PayFineSchema.safeParse({ fine_id: formData.get('fine_id') })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('pay_fine', { p_fine_id: parsed.data.fine_id })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/plata`)
    revalidatePath(`/g/${gid}/plata/multas/${parsed.data.fine_id}`)
    revalidatePath(`/g/${gid}/hoy`)
  }
  return { ok: true }
}

export async function issueManualFine(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = IssueManualFineSchema.safeParse({
    group_id: formData.get('group_id'),
    user_id: formData.get('user_id'),
    amount: formData.get('amount'),
    reason: formData.get('reason'),
    rule_id: formData.get('rule_id') || null,
    event_id: formData.get('event_id') || null,
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('issue_manual_fine', {
    p_group_id: parsed.data.group_id,
    p_user_id: parsed.data.user_id,
    p_amount: parsed.data.amount,
    p_reason: parsed.data.reason,
    p_rule_id: parsed.data.rule_id ?? null,
    p_event_id: parsed.data.event_id ?? null,
  })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath(`/g/${parsed.data.group_id}/plata`)
  revalidatePath(`/g/${parsed.data.group_id}/hoy`)
  return { ok: true }
}

/**
 * openFineAppeal — opens a fine_appeal vote and links it to the fine.
 * Wraps create_vote with subject_type='fine_appeal' (the close_vote RPC
 * already handles the side-effect: passed appeal → fine.waived=true).
 */
export async function openFineAppeal(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = OpenFineAppealSchema.safeParse({
    fine_id: formData.get('fine_id'),
    reason: formData.get('reason'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  // Fetch fine to derive group_id and ensure it's appealable
  const { data: fine, error: fErr } = await supabase
    .from('fines')
    .select('id, group_id, paid, waived, appeal_vote_id, reason, amount')
    .eq('id', parsed.data.fine_id)
    .maybeSingle()
  if (fErr || !fine) return { error: { _form: ['Multa no encontrada'] } }
  if (fine.paid)   return { error: { _form: ['Esta multa ya está pagada — no se puede apelar'] } }
  if (fine.waived) return { error: { _form: ['Esta multa ya está anulada'] } }
  if (fine.appeal_vote_id) return { error: { _form: ['Ya hay una apelación abierta para esta multa'] } }

  // Determine if appeals are committee-only for this group
  const { data: group } = await supabase
    .from('groups')
    .select('committee_required_for_appeals')
    .eq('id', fine.group_id)
    .single()
  const committeeOnly = group?.committee_required_for_appeals ?? false

  // Create the vote
  const { data: vote, error: vErr } = await supabase.rpc('create_vote', {
    p_group_id: fine.group_id,
    p_subject_type: 'fine_appeal',
    p_subject_id: parsed.data.fine_id,
    p_title: `Apelación: ${fine.reason}`,
    p_description: parsed.data.reason,
    p_payload: null,
    p_committee_only: committeeOnly,
  })
  if (vErr || !vote) return { error: { _form: [vErr?.message ?? 'No se pudo abrir la votación'] } }

  // Link the vote back to the fine for easy lookup
  await supabase
    .from('fines')
    .update({ appeal_vote_id: (vote as { id: string }).id })
    .eq('id', parsed.data.fine_id)

  revalidatePath(`/g/${fine.group_id}/plata`)
  revalidatePath(`/g/${fine.group_id}/plata/multas/${parsed.data.fine_id}`)
  revalidatePath(`/g/${fine.group_id}/hoy`)
  return { ok: true }
}
