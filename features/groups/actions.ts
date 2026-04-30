'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { CreateGroupSchema, UpdateGroupSettingsSchema } from './schemas'

export type ActionResult = { ok: true } | { error: { _form?: string[]; [k: string]: string[] | undefined } }

export async function createGroup(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CreateGroupSchema.safeParse({
    name: formData.get('name'),
    event_label: formData.get('event_label') ?? 'Tanda',
    currency: formData.get('currency') ?? 'MXN',
    timezone: formData.get('timezone') ?? 'America/Mexico_City',
    default_day_of_week: formData.get('default_day_of_week') || undefined,
    default_start_time: formData.get('default_start_time') || undefined,
    voting_threshold: formData.get('voting_threshold') ?? 0.5,
    voting_quorum: formData.get('voting_quorum') ?? 0.5,
    fund_enabled: formData.get('fund_enabled') ?? false,
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { data, error } = await supabase.rpc('create_group_with_admin', {
    p_name: parsed.data.name,
    p_description: '',
    p_event_label: parsed.data.event_label,
    p_currency: parsed.data.currency,
    p_timezone: parsed.data.timezone,
    p_default_day: parsed.data.default_day_of_week ?? 0,
    p_default_time: parsed.data.default_start_time ?? '20:30',
    p_default_location: '',
    p_voting_threshold: parsed.data.voting_threshold,
    p_voting_quorum: parsed.data.voting_quorum,
    p_fund_enabled: parsed.data.fund_enabled,
  })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath('/')
  redirect(`/g/${(data as { id: string }).id}`)
}

export async function updateGroupSettings(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = UpdateGroupSettingsSchema.safeParse({
    group_id: formData.get('group_id'),
    name: formData.get('name'),
    event_label: formData.get('event_label') ?? 'Tanda',
    default_day_of_week: formData.get('default_day_of_week') || undefined,
    default_start_time: formData.get('default_start_time') || undefined,
    default_location: formData.get('default_location') || undefined,
    voting_threshold: formData.get('voting_threshold') ?? 0.5,
    voting_quorum: formData.get('voting_quorum') ?? 0.5,
    vote_duration_hours: formData.get('vote_duration_hours') ?? 48,
    no_show_grace_minutes: formData.get('no_show_grace_minutes') ?? 60,
    grace_period_events: formData.get('grace_period_events') ?? 3,
    monthly_fine_cap_mxn: formData.get('monthly_fine_cap_mxn') ?? '',
    fund_enabled: formData.get('fund_enabled') ?? false,
    committee_required_for_appeals: formData.get('committee_required_for_appeals') ?? false,
    block_unpaid_attendance: formData.get('block_unpaid_attendance') ?? false,
    rotation_enabled: formData.get('rotation_enabled') ?? false,
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase
    .from('groups')
    .update({
      name: parsed.data.name,
      event_label: parsed.data.event_label,
      default_day_of_week: parsed.data.default_day_of_week ?? null,
      default_start_time: parsed.data.default_start_time ?? null,
      default_location: parsed.data.default_location ?? null,
      voting_threshold: parsed.data.voting_threshold,
      voting_quorum: parsed.data.voting_quorum,
      vote_duration_hours: parsed.data.vote_duration_hours,
      no_show_grace_minutes: parsed.data.no_show_grace_minutes,
      grace_period_events: parsed.data.grace_period_events,
      monthly_fine_cap_mxn: parsed.data.monthly_fine_cap_mxn ?? null,
      fund_enabled: parsed.data.fund_enabled,
      committee_required_for_appeals: parsed.data.committee_required_for_appeals,
      block_unpaid_attendance: parsed.data.block_unpaid_attendance,
      rotation_enabled: parsed.data.rotation_enabled,
    })
    .eq('id', parsed.data.group_id)
  if (error) return { error: { _form: [error.message] } }

  revalidatePath(`/g/${parsed.data.group_id}`)
  revalidatePath(`/g/${parsed.data.group_id}/mas`)
  revalidatePath(`/g/${parsed.data.group_id}/mas/settings`)
  return { ok: true }
}
