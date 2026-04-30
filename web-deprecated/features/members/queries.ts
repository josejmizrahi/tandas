import 'server-only'
import { createClient } from '@/lib/supabase/server'

export type GroupMemberWithProfile = {
  user_id: string
  role: string
  on_committee: boolean
  turn_order: number | null
  active: boolean
  profiles: { display_name: string } | null
}

export async function listGroupMembers(groupId: string): Promise<GroupMemberWithProfile[]> {
  const supabase = await createClient()

  const { data: members, error } = await supabase
    .from('group_members')
    .select('user_id, role, on_committee, turn_order, active')
    .eq('group_id', groupId)
    .eq('active', true)
    .order('turn_order', { ascending: true, nullsFirst: false })
  if (error) throw error
  if (!members || members.length === 0) return []

  const userIds = members.map((m) => m.user_id)
  const { data: profiles, error: pError } = await supabase
    .from('profiles')
    .select('id, display_name')
    .in('id', userIds)
  if (pError) throw pError

  const byId = new Map((profiles ?? []).map((p) => [p.id, p]))
  return members.map((m) => ({
    user_id: m.user_id,
    role: m.role,
    on_committee: m.on_committee,
    turn_order: m.turn_order,
    active: m.active,
    profiles: byId.get(m.user_id) ? { display_name: byId.get(m.user_id)!.display_name } : null,
  }))
}
