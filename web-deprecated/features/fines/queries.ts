import 'server-only'
import { createClient } from '@/lib/supabase/server'

const FINE_FIELDS = 'id, group_id, user_id, rule_id, event_id, reason, amount, paid, paid_at, paid_to_fund, waived, waived_at, waived_reason, appeal_vote_id, auto_generated, issued_by, created_at'

export type FineRow = {
  id: string
  group_id: string
  user_id: string
  rule_id: string | null
  event_id: string | null
  reason: string
  amount: number
  paid: boolean
  paid_at: string | null
  paid_to_fund: boolean
  waived: boolean
  waived_at: string | null
  waived_reason: string | null
  appeal_vote_id: string | null
  auto_generated: boolean
  issued_by: string | null
  created_at: string
}

export type FineWithProfile = FineRow & {
  display_name: string | null
}

async function attachProfiles(supabase: Awaited<ReturnType<typeof createClient>>, fines: FineRow[]): Promise<FineWithProfile[]> {
  if (fines.length === 0) return []
  const userIds = Array.from(new Set(fines.map((f) => f.user_id)))
  const { data: profiles } = await supabase
    .from('profiles')
    .select('id, display_name')
    .in('id', userIds)
  const byId = new Map((profiles ?? []).map((p) => [p.id, p.display_name]))
  return fines.map((f) => ({ ...f, display_name: byId.get(f.user_id) ?? null }))
}

export async function listMyFines(groupId: string, userId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('fines')
    .select(FINE_FIELDS)
    .eq('group_id', groupId)
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as FineRow[]
}

export async function listGroupFines(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('fines')
    .select(FINE_FIELDS)
    .eq('group_id', groupId)
    .order('created_at', { ascending: false })
    .limit(100)
  if (error) throw error
  return attachProfiles(supabase, (data ?? []) as FineRow[])
}

export async function listMyUnpaidFines(groupId: string, userId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('fines')
    .select(FINE_FIELDS)
    .eq('group_id', groupId)
    .eq('user_id', userId)
    .eq('paid', false)
    .eq('waived', false)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as FineRow[]
}

export async function getFine(fineId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('fines')
    .select(FINE_FIELDS)
    .eq('id', fineId)
    .maybeSingle()
  if (error) throw error
  return data as FineRow | null
}
