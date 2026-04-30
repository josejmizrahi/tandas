import { useQuery } from '@tanstack/react-query'
import { useParams } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/app/providers/AuthProvider'

export function useGroupId() {
  const { groupId } = useParams()
  if (!groupId) throw new Error('groupId missing')
  return groupId
}

export function useGroup(groupId: string) {
  return useQuery({
    queryKey: ['group', groupId],
    queryFn: async () => {
      const { data, error } = await supabase.from('groups').select('*').eq('id', groupId).single()
      if (error) throw error
      return data
    },
  })
}

export type GroupMemberWithProfile = {
  id: string
  group_id: string
  user_id: string
  role: string
  on_committee: boolean
  turn_order: number | null
  active: boolean
  joined_at: string
  display_name_override: string | null
  profile: { id: string; display_name: string; avatar_url: string | null } | null
}

export function useGroupMembers(groupId: string) {
  return useQuery<GroupMemberWithProfile[]>({
    queryKey: ['group-members', groupId],
    queryFn: async () => {
      const { data: members, error } = await supabase
        .from('group_members')
        .select('*')
        .eq('group_id', groupId)
        .eq('active', true)
        .order('turn_order', { ascending: true, nullsFirst: false })
      if (error) throw error
      const ids = (members ?? []).map((m) => m.user_id)
      let profiles: Array<{ id: string; display_name: string; avatar_url: string | null }> = []
      if (ids.length > 0) {
        const { data: ps, error: pe } = await supabase
          .from('profiles')
          .select('id, display_name, avatar_url')
          .in('id', ids)
        if (pe) throw pe
        profiles = ps ?? []
      }
      return (members ?? []).map((m) => ({
        ...m,
        profile: profiles.find((p) => p.id === m.user_id) ?? null,
      }))
    },
  })
}

export function useMyMembership(groupId: string) {
  const { user } = useAuth()
  const { data: members } = useGroupMembers(groupId)
  return members?.find((m) => m.user_id === user?.id) ?? null
}
