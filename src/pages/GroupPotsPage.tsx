import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, Plus, Trophy, Users } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useGroup, useGroupId, useGroupMembers } from '@/hooks/useGroupContext'
import { useAuth } from '@/app/providers/AuthProvider'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { EmptyState } from '@/components/ui/empty-state'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { formatCurrency } from '@/lib/utils'

export function GroupPotsPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const { data: group } = useGroup(groupId)
  const { data: members } = useGroupMembers(groupId)

  const pots = useQuery({
    queryKey: ['pots', groupId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('pots')
        .select('*, entries:pot_entries(*)')
        .eq('group_id', groupId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as unknown as Array<{
        id: string
        name: string
        buy_in: number
        currency: string
        status: string
        winner_id: string | null
        created_by: string | null
        entries: Array<{ id: string; pot_id: string; user_id: string; amount: number; paid_to_winner: boolean }>
      }>
    },
  })

  const memberName = (uid: string) =>
    members?.find((m) => m.user_id === uid)?.profile?.display_name ?? '—'

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <Button variant="ghost" size="sm" onClick={() => navigate(`/grupos/${groupId}`)} className="-ml-3">
          <ArrowLeft className="h-4 w-4" /> Volver
        </Button>
        <NewPotDialog groupId={groupId} currency={group?.currency ?? 'MXN'} />
      </div>
      <div>
        <h1 className="text-2xl font-semibold">Pots de juego</h1>
        <p className="text-sm text-muted-foreground">
          Poker, Happy King, etc. Cada quien entra con un buy-in. Cuando declares ganador, los demás le deben automáticamente.
        </p>
      </div>

      {pots.isLoading ? (
        <div className="text-sm text-muted-foreground">Cargando…</div>
      ) : !pots.data?.length ? (
        <EmptyState icon={<Trophy className="h-8 w-8" />} title="Sin pots todavía" description="Crea uno cuando empiecen a jugar." />
      ) : (
        <div className="space-y-3">
          {pots.data.map((p) => (
            <PotCard key={p.id} pot={p} groupId={groupId} memberName={memberName} />
          ))}
        </div>
      )}
    </div>
  )
}

function PotCard({ pot, groupId, memberName }: { pot: { id: string; name: string; buy_in: number; currency: string; status: string; winner_id: string | null; entries: Array<{ id: string; user_id: string; amount: number; paid_to_winner: boolean }> }; groupId: string; memberName: (uid: string) => string }) {
  const qc = useQueryClient()
  const { user } = useAuth()
  const [winner, setWinner] = useState('')

  const join = useMutation({
    mutationFn: async () => {
      if (!user) throw new Error('no auth')
      const { error } = await supabase
        .from('pot_entries')
        .upsert({ pot_id: pot.id, user_id: user.id, amount: pot.buy_in }, { onConflict: 'pot_id,user_id' })
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['pots', groupId] }),
    onError: (e: Error) => toast.error(e.message),
  })

  const close = useMutation({
    mutationFn: async () => {
      if (!winner) throw new Error('selecciona ganador')
      const { error } = await supabase.rpc('close_pot', { p_pot_id: pot.id, p_winner_id: winner })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['pots', groupId] })
      qc.invalidateQueries({ queryKey: ['balances', groupId] })
      toast.success('Pot cerrado. Se generaron los IOUs al ganador.')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const markPaid = useMutation({
    mutationFn: async (entryId: string) => {
      const { error } = await supabase
        .from('pot_entries')
        .update({ paid_to_winner: true, paid_at: new Date().toISOString() })
        .eq('id', entryId)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['pots', groupId] }),
    onError: (e: Error) => toast.error(e.message),
  })

  const myEntry = pot.entries.find((e) => e.user_id === user?.id)
  const total = pot.entries.reduce((s, e) => s + Number(e.amount), 0)

  return (
    <Card>
      <CardHeader>
        <div className="flex items-start justify-between">
          <div>
            <CardTitle className="text-base">{pot.name}</CardTitle>
            <div className="text-xs text-muted-foreground">
              Buy-in: {formatCurrency(Number(pot.buy_in), pot.currency)} · {pot.entries.length} jugadores · Pot total: {formatCurrency(total, pot.currency)}
            </div>
          </div>
          <Badge variant={pot.status === 'open' ? 'warning' : pot.status === 'closed' ? 'success' : 'secondary'}>
            {pot.status === 'open' ? 'Abierto' : pot.status === 'closed' ? 'Cerrado' : 'Cancelado'}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        <div className="space-y-1">
          {pot.entries.map((e) => (
            <div key={e.id} className="flex items-center justify-between rounded border p-2 text-xs">
              <div className="flex items-center gap-2">
                <Users className="h-3.5 w-3.5 text-muted-foreground" />
                <span>{memberName(e.user_id)}</span>
                {pot.winner_id === e.user_id && <Badge variant="success">Ganador</Badge>}
              </div>
              <div className="flex items-center gap-2">
                <span>{formatCurrency(Number(e.amount), pot.currency)}</span>
                {pot.status === 'closed' && pot.winner_id && pot.winner_id !== e.user_id && (
                  e.paid_to_winner ? <Badge variant="success">Pagado</Badge> : (
                    <Button size="sm" variant="outline" onClick={() => markPaid.mutate(e.id)}>Marcar pagado</Button>
                  )
                )}
              </div>
            </div>
          ))}
        </div>
        {pot.status === 'open' && (
          <div className="flex flex-wrap items-center gap-2">
            {!myEntry && (
              <Button size="sm" onClick={() => join.mutate()}>Entrar al pot</Button>
            )}
            <div className="ml-auto flex items-center gap-2">
              <Select value={winner} onValueChange={setWinner}>
                <SelectTrigger className="h-8 w-[180px]"><SelectValue placeholder="Ganador" /></SelectTrigger>
                <SelectContent>
                  {pot.entries.map((e) => (
                    <SelectItem key={e.user_id} value={e.user_id}>{memberName(e.user_id)}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button size="sm" variant="outline" onClick={() => close.mutate()} disabled={!winner}>
                Declarar ganador
              </Button>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function NewPotDialog({ groupId, currency }: { groupId: string; currency: string }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [form, setForm] = useState({ name: 'Poker', buy_in: '100' })

  const create = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('pots').insert({
        group_id: groupId,
        name: form.name,
        buy_in: Number(form.buy_in),
        currency,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['pots', groupId] })
      setOpen(false)
      toast.success('Pot creado')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function onSubmit(e: FormEvent) { e.preventDefault(); create.mutate() }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button><Plus className="h-4 w-4" /> Nuevo pot</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader><DialogTitle>Nuevo pot</DialogTitle></DialogHeader>
        <form onSubmit={onSubmit} className="space-y-3">
          <div className="space-y-1.5">
            <Label>Nombre del juego</Label>
            <Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required />
          </div>
          <div className="space-y-1.5">
            <Label>Buy-in</Label>
            <Input type="number" min="0" step="1" value={form.buy_in} onChange={(e) => setForm({ ...form, buy_in: e.target.value })} required />
          </div>
          <DialogFooter><Button type="submit" disabled={create.isPending}>{create.isPending ? 'Creando…' : 'Crear pot'}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
