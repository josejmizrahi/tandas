import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, Plus, Check, Vote, Sparkles } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useGroup, useGroupId, useGroupMembers, useMyMembership } from '@/hooks/useGroupContext'
import { useAuth } from '@/app/providers/AuthProvider'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { EmptyState } from '@/components/ui/empty-state'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { formatCurrency, formatDate } from '@/lib/utils'

export function GroupFinesPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const { user } = useAuth()
  const { data: group } = useGroup(groupId)
  const { data: members } = useGroupMembers(groupId)
  const me = useMyMembership(groupId)
  const isAdmin = me?.role === 'admin'
  const qc = useQueryClient()

  const fines = useQuery({
    queryKey: ['fines', groupId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('fines')
        .select('*')
        .eq('group_id', groupId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data
    },
  })

  const pay = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('pay_fine', { p_fine_id: id })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['fines', groupId] })
      qc.invalidateQueries({ queryKey: ['group', groupId] })
      toast.success('Multa pagada')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const appeal = useMutation({
    mutationFn: async (fineId: string) => {
      const { data: vote, error } = await supabase.rpc('create_vote', {
        p_group_id: groupId,
        p_subject_type: 'fine_appeal',
        p_subject_id: fineId,
        p_title: 'Apelación de multa',
        p_description: 'El miembro impugna esta multa.',
        p_payload: null,
        p_committee_only: !!group?.committee_required_for_appeals,
      })
      if (error) throw error
      const { error: e2 } = await supabase.from('fines').update({ appeal_vote_id: vote.id }).eq('id', fineId)
      if (e2) throw e2
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['fines', groupId] })
      qc.invalidateQueries({ queryKey: ['votes', groupId] })
      toast.success('Apelación abierta para votación')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const memberName = (uid: string) =>
    members?.find((m) => m.user_id === uid)?.profile?.display_name ?? '—'

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <Button variant="ghost" size="sm" onClick={() => navigate(`/grupos/${groupId}`)} className="-ml-3">
          <ArrowLeft className="h-4 w-4" /> Volver
        </Button>
        {isAdmin && <ManualFineDialog groupId={groupId} />}
      </div>

      <div>
        <h1 className="text-2xl font-semibold">Multas</h1>
        <p className="text-sm text-muted-foreground">
          Las multas auto-generadas vienen del cierre de eventos. Las multas pagadas{' '}
          {group?.fund_enabled ? 'van al fondo del grupo' : 'son entre miembros'}.
        </p>
      </div>

      {fines.isLoading ? (
        <div className="text-sm text-muted-foreground">Cargando…</div>
      ) : !fines.data?.length ? (
        <EmptyState title="Sin multas" description="Cuando se cierre un evento se generarán automáticamente." />
      ) : (
        <div className="space-y-2">
          {fines.data.map((f) => {
            const mine = f.user_id === user?.id
            return (
              <Card key={f.id}>
                <CardHeader className="flex-row items-start justify-between space-y-0">
                  <div>
                    <CardTitle className="text-base">{f.reason}</CardTitle>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                      <span>{memberName(f.user_id)}</span>
                      <span>·</span>
                      <span>{formatDate(f.created_at)}</span>
                      {f.auto_generated && <Badge variant="outline"><Sparkles className="mr-1 h-3 w-3" /> Auto</Badge>}
                    </div>
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-1">
                    <span className="text-lg font-semibold">{formatCurrency(Number(f.amount), group?.currency ?? 'MXN')}</span>
                    {f.waived ? (
                      <Badge variant="secondary">Anulada</Badge>
                    ) : f.paid ? (
                      <Badge variant="success">Pagada</Badge>
                    ) : (
                      <Badge variant="warning">Pendiente</Badge>
                    )}
                  </div>
                </CardHeader>
                <CardContent className="flex flex-wrap gap-2 pt-0">
                  {!f.paid && !f.waived && (mine || isAdmin) && (
                    <Button size="sm" variant="outline" onClick={() => pay.mutate(f.id)}>
                      <Check className="h-4 w-4" /> Marcar pagada
                    </Button>
                  )}
                  {!f.paid && !f.waived && !f.appeal_vote_id && mine && (
                    <Button size="sm" variant="ghost" onClick={() => appeal.mutate(f.id)}>
                      <Vote className="h-4 w-4" /> Apelar
                    </Button>
                  )}
                  {f.appeal_vote_id && <Badge variant="outline">Apelación abierta</Badge>}
                </CardContent>
              </Card>
            )
          })}
        </div>
      )}
    </div>
  )
}

function ManualFineDialog({ groupId }: { groupId: string }) {
  const qc = useQueryClient()
  const { data: members } = useGroupMembers(groupId)
  const [open, setOpen] = useState(false)
  const [form, setForm] = useState({ user_id: '', reason: '', amount: '' })

  const create = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('fines').insert({
        group_id: groupId,
        user_id: form.user_id,
        reason: form.reason,
        amount: Number(form.amount),
        auto_generated: false,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['fines', groupId] })
      setOpen(false)
      toast.success('Multa registrada')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    create.mutate()
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button><Plus className="h-4 w-4" /> Multa manual</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Multa manual</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-3">
          <div className="space-y-1.5">
            <Label>Miembro</Label>
            <Select value={form.user_id} onValueChange={(v) => setForm({ ...form, user_id: v })}>
              <SelectTrigger><SelectValue placeholder="Selecciona miembro" /></SelectTrigger>
              <SelectContent>
                {members?.map((m) => (
                  <SelectItem key={m.user_id} value={m.user_id}>{m.profile?.display_name ?? m.user_id}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>Razón</Label>
            <Textarea value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} required />
          </div>
          <div className="space-y-1.5">
            <Label>Monto</Label>
            <Input type="number" min="0" step="0.01" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} required />
          </div>
          <DialogFooter>
            <Button type="submit" disabled={create.isPending || !form.user_id}>
              {create.isPending ? 'Creando…' : 'Aplicar multa'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
