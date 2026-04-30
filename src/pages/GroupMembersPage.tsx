import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, ChevronUp, ChevronDown, Crown, Shield, ShieldCheck } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useGroup, useGroupId, useGroupMembers, useMyMembership } from '@/hooks/useGroupContext'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { initials } from '@/lib/utils'

export function GroupMembersPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const { data: group } = useGroup(groupId)
  const { data: members } = useGroupMembers(groupId)
  const me = useMyMembership(groupId)
  const isAdmin = me?.role === 'admin'
  const qc = useQueryClient()

  const reorder = useMutation({
    mutationFn: async (userIds: string[]) => {
      const { error } = await supabase.rpc('set_turn_order', {
        p_group_id: groupId,
        p_user_ids: userIds,
      })
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['group-members', groupId] }),
    onError: (e: Error) => toast.error(e.message),
  })

  const update = useMutation({
    mutationFn: async ({
      id,
      patch,
    }: {
      id: string
      patch: { role?: string; on_committee?: boolean; active?: boolean; turn_order?: number | null }
    }) => {
      const { error } = await supabase.from('group_members').update(patch).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['group-members', groupId] })
      toast.success('Miembro actualizado')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function move(idx: number, dir: -1 | 1) {
    if (!members) return
    const next = [...members]
    const target = idx + dir
    if (target < 0 || target >= next.length) return
    ;[next[idx], next[target]] = [next[target], next[idx]]
    reorder.mutate(next.map((m) => m.user_id))
  }

  if (!group) return null

  return (
    <div className="space-y-4">
      <Button variant="ghost" size="sm" onClick={() => navigate(`/grupos/${groupId}`)} className="-ml-3">
        <ArrowLeft className="h-4 w-4" /> Volver
      </Button>
      <div className="flex items-end justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Miembros</h1>
          <p className="text-sm text-muted-foreground">
            Orden de turnos para hospedar (rotación). Comparte el código <span className="font-mono">{group.invite_code}</span> para invitar.
          </p>
        </div>
      </div>

      <Card>
        <CardHeader><CardTitle className="text-base">Orden de la {group.event_label.toLowerCase()}</CardTitle></CardHeader>
        <CardContent className="space-y-2">
          {members?.map((m, i) => (
            <div key={m.id} className="flex items-center justify-between rounded-md border p-2">
              <div className="flex min-w-0 items-center gap-3">
                <span className="w-6 shrink-0 text-sm font-mono text-muted-foreground">{i + 1}.</span>
                <Avatar className="h-9 w-9"><AvatarFallback>{initials(m.profile?.display_name ?? '?')}</AvatarFallback></Avatar>
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="truncate font-medium">{m.profile?.display_name ?? 'miembro'}</span>
                    {m.role === 'admin' && <Badge><Shield className="mr-1 h-3 w-3" /> Admin</Badge>}
                    {m.on_committee && <Badge variant="outline"><ShieldCheck className="mr-1 h-3 w-3" /> Comité</Badge>}
                  </div>
                </div>
              </div>
              {isAdmin && (
                <div className="flex shrink-0 items-center gap-1">
                  <Button size="icon" variant="ghost" disabled={i === 0} onClick={() => move(i, -1)} title="Subir">
                    <ChevronUp className="h-4 w-4" />
                  </Button>
                  <Button size="icon" variant="ghost" disabled={i === (members?.length ?? 0) - 1} onClick={() => move(i, 1)} title="Bajar">
                    <ChevronDown className="h-4 w-4" />
                  </Button>
                  <Button
                    size="sm"
                    variant={m.on_committee ? 'secondary' : 'ghost'}
                    onClick={() => update.mutate({ id: m.id, patch: { on_committee: !m.on_committee } })}
                  >
                    {m.on_committee ? 'Quitar comité' : 'Comité'}
                  </Button>
                  <Button
                    size="sm"
                    variant={m.role === 'admin' ? 'secondary' : 'ghost'}
                    onClick={() => update.mutate({ id: m.id, patch: { role: m.role === 'admin' ? 'member' : 'admin' } })}
                  >
                    <Crown className="h-4 w-4" /> {m.role === 'admin' ? 'Quitar admin' : 'Hacer admin'}
                  </Button>
                </div>
              )}
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  )
}
