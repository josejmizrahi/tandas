'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import {
  CreateEventSchema,
  SetRsvpSchema,
  CheckInSchema,
  CloseEventSchema,
} from './schemas'

export type ActionResult = { ok: true } | { error: { _form?: string[]; [k: string]: string[] | undefined } }

export async function createEvent(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CreateEventSchema.safeParse({
    group_id: formData.get('group_id'),
    starts_at: formData.get('starts_at'),
    location: formData.get('location') || undefined,
    title: formData.get('title') || undefined,
    rsvp_deadline: formData.get('rsvp_deadline') || undefined,
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { data, error } = await supabase.rpc('create_event', {
    p_group_id: parsed.data.group_id,
    p_starts_at: parsed.data.starts_at,
    p_ends_at: parsed.data.starts_at,
    p_location: parsed.data.location ?? '',
    p_title: parsed.data.title ?? '',
    p_host_id: user.id,
    p_cycle_number: 1,
    p_rsvp_deadline: parsed.data.rsvp_deadline ?? parsed.data.starts_at,
  })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath(`/g/${parsed.data.group_id}/eventos`)
  revalidatePath(`/g/${parsed.data.group_id}/hoy`)
  redirect(`/g/${parsed.data.group_id}/eventos/${(data as { id: string }).id}`)
}

export async function setRsvp(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = SetRsvpSchema.safeParse({
    event_id: formData.get('event_id'),
    status: formData.get('status'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('set_rsvp', {
    p_event_id: parsed.data.event_id,
    p_status: parsed.data.status,
  })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/hoy`)
    revalidatePath(`/g/${gid}/eventos`)
    revalidatePath(`/g/${gid}/eventos/${parsed.data.event_id}`)
  }
  return { ok: true }
}

export async function checkInAttendee(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CheckInSchema.safeParse({
    event_id: formData.get('event_id'),
    user_id: formData.get('user_id'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('check_in_attendee', {
    p_event_id: parsed.data.event_id,
    p_user_id: parsed.data.user_id,
    p_arrived_at: new Date().toISOString(),
  })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) revalidatePath(`/g/${gid}/eventos/${parsed.data.event_id}`)
  return { ok: true }
}

export async function closeEvent(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = CloseEventSchema.safeParse({
    event_id: formData.get('event_id'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { error } = await supabase.rpc('close_event', { p_event_id: parsed.data.event_id })
  if (error) return { error: { _form: [error.message] } }

  const gid = formData.get('gid') as string | null
  if (gid) {
    revalidatePath(`/g/${gid}/hoy`)
    revalidatePath(`/g/${gid}/eventos`)
    revalidatePath(`/g/${gid}/eventos/${parsed.data.event_id}`)
  }
  return { ok: true }
}
