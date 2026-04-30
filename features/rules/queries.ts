import 'server-only'
import { createClient } from '@/lib/supabase/server'

const RULE_FIELDS = 'id, group_id, title, description, trigger, action, exceptions, status, enabled, approved_via_vote_id, proposed_by, created_at'

export async function listActiveRules(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('rules')
    .select(RULE_FIELDS)
    .eq('group_id', groupId)
    .eq('status', 'active')
    .order('created_at', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function listProposedRules(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('rules')
    .select(RULE_FIELDS)
    .eq('group_id', groupId)
    .eq('status', 'proposed')
    .order('created_at', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function listArchivedRules(groupId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('rules')
    .select(RULE_FIELDS)
    .eq('group_id', groupId)
    .eq('status', 'archived')
    .order('created_at', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function getRule(ruleId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('rules')
    .select(RULE_FIELDS)
    .eq('id', ruleId)
    .maybeSingle()
  if (error) throw error
  return data
}

export type RuleRow = NonNullable<Awaited<ReturnType<typeof getRule>>>
