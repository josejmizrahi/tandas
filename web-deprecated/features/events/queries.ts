import 'server-only'
import { createClient } from '@/lib/supabase/server'

export async function listUpcomingEvents(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, starts_at, location, title, status, host_id, cycle_number')
    .eq('group_id', groupId)
    .gte('starts_at', new Date().toISOString())
    .order('starts_at', { ascending: true })
    .limit(20)
  if (error) throw error
  return data ?? []
}

export async function listPastEvents(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, starts_at, location, title, status, host_id, cycle_number')
    .eq('group_id', groupId)
    .lt('starts_at', new Date().toISOString())
    .order('starts_at', { ascending: false })
    .limit(50)
  if (error) throw error
  return data ?? []
}

export async function getNextEventForGroup(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, starts_at, location, title, status, host_id')
    .eq('group_id', groupId)
    .gte('starts_at', new Date().toISOString())
    .order('starts_at', { ascending: true })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function getEvent(eventId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('events')
    .select('id, group_id, starts_at, ends_at, location, title, status, host_id, cycle_number, rsvp_deadline, parent_event_id, auto_no_show_at, rules_evaluated_at')
    .eq('id', eventId)
    .maybeSingle()
  if (error) throw error
  return data
}

export type AttendanceWithProfile = {
  user_id: string
  rsvp_status: string
  rsvp_at: string | null
  arrived_at: string | null
  cancelled_same_day: boolean
  no_show: boolean
  display_name: string | null
}

export async function listAttendance(eventId: string): Promise<AttendanceWithProfile[]> {
  const supabase = await createClient()
  const { data: rows, error } = await supabase
    .from('event_attendance')
    .select('user_id, rsvp_status, rsvp_at, arrived_at, cancelled_same_day, no_show')
    .eq('event_id', eventId)
  if (error) throw error
  if (!rows || rows.length === 0) return []

  const userIds = rows.map((r) => r.user_id)
  const { data: profiles } = await supabase
    .from('profiles')
    .select('id, display_name')
    .in('id', userIds)
  const byId = new Map((profiles ?? []).map((p) => [p.id, p.display_name]))

  return rows.map((r) => ({
    user_id: r.user_id,
    rsvp_status: r.rsvp_status,
    rsvp_at: r.rsvp_at,
    arrived_at: r.arrived_at,
    cancelled_same_day: r.cancelled_same_day,
    no_show: r.no_show,
    display_name: byId.get(r.user_id) ?? null,
  }))
}

export async function getMyAttendance(eventId: string, userId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('event_attendance')
    .select('user_id, rsvp_status, arrived_at, cancelled_same_day, no_show')
    .eq('event_id', eventId)
    .eq('user_id', userId)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function isAdminOfGroup(groupId: string, userId: string): Promise<boolean> {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('group_members')
    .select('role')
    .eq('group_id', groupId)
    .eq('user_id', userId)
    .eq('active', true)
    .maybeSingle()
  if (error) throw error
  return data?.role === 'admin'
}
