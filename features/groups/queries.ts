import 'server-only'
import { createClient } from '@/lib/supabase/server'

export async function listMyGroups() {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('group_members')
    .select('group_id, groups(id, name, invite_code, currency, fund_enabled, fund_balance)')
    .eq('active', true)
  if (error) throw error
  return data ?? []
}

export async function getGroup(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('groups')
    .select('id, name, description, event_label, currency, timezone, default_day_of_week, default_start_time, default_location, voting_threshold, voting_quorum, fund_enabled, fund_balance, invite_code')
    .eq('id', groupId)
    .maybeSingle()
  if (error) throw error
  return data
}
