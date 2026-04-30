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
