import 'server-only'
import { createClient } from '@/lib/supabase/server'

export async function listGroupMembers(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('group_members')
    .select('user_id, role, on_committee, turn_order, active, profiles!user_id(display_name)')
    .eq('group_id', groupId)
    .eq('active', true)
    .order('turn_order', { ascending: true, nullsFirst: false })
  if (error) throw error
  return data ?? []
}
