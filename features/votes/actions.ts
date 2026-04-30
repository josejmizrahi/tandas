'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { CastBallotSchema, CloseVoteSchema } from './schemas'

export type ActionResult = { ok: true } | { error: { _form?: string[]; [k: string]: string[] | undefined } }

export async function castBallot(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CastBallotSchema.safeParse({
    vote_id: formData.get('vote_id'),
    choice: formData.get('choice'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('cast_ballot', {
    p_vote_id: parsed.data.vote_id,
    p_choice: parsed.data.choice,
  })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  const ruleId = formData.get('rule_id') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/hoy`)
    if (ruleId) revalidatePath(`/g/${gid}/reglas/${ruleId}`)
  }
  return { ok: true }
}

/**
 * requestAmnesty — admin opens an amnesty vote that, if it passes, waives
 * ALL unpaid+unwaived fines in the group at the moment of close.
 */
export async function requestAmnesty(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const groupId = formData.get('group_id') as string | null
  const reason = (formData.get('reason') as string | null)?.trim() ?? ''
  if (!groupId) return { error: { _form: ['Falta group_id'] } }
  if (reason.length < 2) return { error: { reason: ['Cuéntale al grupo por qué propones la amnistía'] } }

  const { error } = await supabase.rpc('create_vote', {
    p_group_id: groupId,
    p_subject_type: 'amnesty',
    p_subject_id: null as unknown as string, // SQL accepts null; types are tighter than reality
    p_title: 'Amnistía general',
    p_description: reason,
    p_payload: null as unknown as never,
    p_committee_only: false,
  })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath(`/g/${groupId}/plata`)
  revalidatePath(`/g/${groupId}/hoy`)
  return { ok: true }
}

export async function closeVote(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CloseVoteSchema.safeParse({ vote_id: formData.get('vote_id') })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('close_vote', { p_vote_id: parsed.data.vote_id })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  const ruleId = formData.get('rule_id') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/hoy`)
    revalidatePath(`/g/${gid}/reglas`)
    if (ruleId) revalidatePath(`/g/${gid}/reglas/${ruleId}`)
  }
  return { ok: true }
}
