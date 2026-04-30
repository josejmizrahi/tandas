'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import type { Json } from '@/lib/db/types'
import {
  ProposeRuleSchema,
  ArchiveRuleSchema,
  UpdateExceptionsSchema,
} from './schemas'

export type ActionResult = { ok: true } | { error: { _form?: string[]; [k: string]: string[] | undefined } }

export async function proposeRule(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const triggerRaw = formData.get('trigger') as string | null
  const actionRaw  = formData.get('action') as string | null
  if (!triggerRaw || !actionRaw) return { error: { _form: ['Falta trigger o action'] } }

  let triggerJson: unknown
  let actionJson: unknown
  try {
    triggerJson = JSON.parse(triggerRaw)
    actionJson  = JSON.parse(actionRaw)
  } catch {
    return { error: { _form: ['JSON inválido en trigger/action'] } }
  }

  const parsed = ProposeRuleSchema.safeParse({
    group_id: formData.get('group_id'),
    title: formData.get('title'),
    description: formData.get('description') || undefined,
    trigger: triggerJson,
    action: actionJson,
    exceptions: [],
    committee_only: formData.get('committee_only') ?? false,
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { data, error } = await supabase.rpc('propose_rule', {
    p_group_id: parsed.data.group_id,
    p_title: parsed.data.title,
    p_description: parsed.data.description ?? '',
    p_trigger: parsed.data.trigger as unknown as Json,
    p_action: parsed.data.action as unknown as Json,
    p_exceptions: parsed.data.exceptions as unknown as Json,
    p_committee_only: parsed.data.committee_only ?? false,
  })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath(`/g/${parsed.data.group_id}/reglas`)
  revalidatePath(`/g/${parsed.data.group_id}/hoy`)
  redirect(`/g/${parsed.data.group_id}/reglas/${(data as { id: string }).id}`)
}

export async function archiveRule(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = ArchiveRuleSchema.safeParse({ rule_id: formData.get('rule_id') })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase
    .from('rules')
    .update({ status: 'archived', enabled: false })
    .eq('id', parsed.data.rule_id)
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/reglas`)
    revalidatePath(`/g/${gid}/reglas/${parsed.data.rule_id}`)
  }
  return { ok: true }
}

export async function updateRuleExceptions(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const userIdsRaw = formData.getAll('user_ids') as string[]
  const parsed = UpdateExceptionsSchema.safeParse({
    rule_id: formData.get('rule_id'),
    user_ids: userIdsRaw,
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const exceptions = parsed.data.user_ids.map((uid) => ({ user_id: uid }))
  const { error } = await supabase
    .from('rules')
    .update({ exceptions: exceptions as unknown as Json })
    .eq('id', parsed.data.rule_id)
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) revalidatePath(`/g/${gid}/reglas/${parsed.data.rule_id}`)
  return { ok: true }
}
