'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { CreateGroupSchema } from './schemas'

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
