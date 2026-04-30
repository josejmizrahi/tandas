import { useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, ThumbsUp, ThumbsDown, MinusCircle, Hammer, Plus } from 'lucide-react'
import { useState, type FormEvent } from 'react'
import { supabase } from '@/lib/supabase'
import { useGroupId, useMyMembership } from '@/hooks/useGroupContext'
import { useAuth } from '@/app/providers/AuthProvider'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { EmptyState } from '@/components/ui/empty-state'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { formatDateTime } from '@/lib/utils'

const SUBJECT_LABELS: Record<string, string> = {
  rule_proposal: 'Propuesta de regla',
  rule_repeal: 'Derogación de regla',
  fine_appeal: 'Apelación de multa',
  host_swap: 'Cambio de turno',
  general: 'General',
}

export function GroupVotesPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const me = useMyMembership(groupId)
  const isAdmin = me?.role === 'admin'

  const votes = useQuery({
    queryKey: ['votes', groupId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('votes')
        .select('*')
        .eq('group_id', groupId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data
    },
  })

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <Button variant="ghost" size="sm" onClick={() => navigate(`/grupos/${groupId}`)} className="-ml-3">
          <ArrowLeft className="h-4 w-4" /> Volver
        </Button>
        <NewGeneralVoteDialog groupId={groupId} />
      </div>

      <div>
        <h1 className="text-2xl font-semibold">Votaciones</h1>
        <p className="text-sm text-muted-foreground">
          Propuestas de reglas, apelaciones y decisiones generales del grupo.
        </p>
      </div>

      {votes.isLoading ? (
        <div className="text-sm text-muted-foreground">Cargando…</div>
      ) : !votes.data?.length ? (
        <EmptyState title="Sin votaciones" description="Las propuestas y apelaciones aparecerán aquí." />
      ) : (
        <div className="space-y-3">
          {votes.data.map((v) => (
            <VoteCard key={v.id} vote={v} groupId={groupId} isAdmin={isAdmin} />
          ))}
        </div>
      )}
    </div>
  )
}

function VoteCard({ vote, groupId, isAdmin }: { vote: { id: string; subject_type: string; status: string; title: string; description: string | null; closes_at: string; committee_only: boolean; result: unknown; threshold: number; quorum: number }; groupId: string; isAdmin: boolean }) {
  const qc = useQueryClient()
  const { user } = useAuth()
  const myBallot = useQuery({
    queryKey: ['my-ballot', vote.id, user?.id],
    enabled: !!user,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('vote_ballots')
        .select('*')
        .eq('vote_id', vote.id)
        .eq('user_id', user!.id)
        .maybeSingle()
      if (error) throw error
      return data
    },
  })

  const cast = useMutation({
    mutationFn: async (choice: 'yes' | 'no' | 'abstain') => {
      if (!user) throw new Error('no auth')
      const { error } = await supabase
        .from('vote_ballots')
        .upsert({ vote_id: vote.id, user_id: user.id, choice }, { onConflict: 'vote_id,user_id' })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['my-ballot', vote.id] })
      toast.success('Voto registrado')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const close = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('close_vote', { p_vote_id: vote.id })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['votes', groupId] })
      qc.invalidateQueries({ queryKey: ['rules', groupId] })
      qc.invalidateQueries({ queryKey: ['fines', groupId] })
      toast.success('Votación cerrada')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const result = vote.result as { yes?: number; no?: number; abstain?: number; total?: number; eligible?: number } | null

  return (
    <Card>
      <CardHeader>
        <div className="flex items-start justify-between gap-3">
          <div>
            <CardTitle className="text-base">{vote.title}</CardTitle>
            <CardDescription>{SUBJECT_LABELS[vote.subject_type] ?? vote.subject_type}</CardDescription>
            {vote.description && <p className="mt-1 text-sm text-muted-foreground">{vote.description}</p>}
          </div>
          <Badge variant={vote.status === 'open' ? 'warning' : vote.status === 'passed' ? 'success' : 'destructive'}>
            {vote.status === 'open' ? 'Abierta' : vote.status === 'passed' ? 'Aprobada' : vote.status === 'rejected' ? 'Rechazada' : 'Cancelada'}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        <div className="text-xs text-muted-foreground">
          Cierra: {formatDateTime(vote.closes_at)}
          {vote.committee_only && ' · solo comité'}
          {' · '}mayoría {Math.round(vote.threshold * 100)}%, quórum {Math.round(vote.quorum * 100)}%
        </div>

        {result && (
          <div className="grid grid-cols-3 gap-2 rounded-md bg-muted/50 p-2 text-center text-xs">
            <div><div className="font-semibold">Sí</div>{result.yes ?? 0}</div>
            <div><div className="font-semibold">No</div>{result.no ?? 0}</div>
            <div><div className="font-semibold">Abst.</div>{result.abstain ?? 0}</div>
          </div>
        )}

        {vote.status === 'open' && (
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant={myBallot.data?.choice === 'yes' ? 'default' : 'outline'} onClick={() => cast.mutate('yes')}>
              <ThumbsUp className="h-4 w-4" /> Sí
            </Button>
            <Button size="sm" variant={myBallot.data?.choice === 'no' ? 'default' : 'outline'} onClick={() => cast.mutate('no')}>
              <ThumbsDown className="h-4 w-4" /> No
            </Button>
            <Button size="sm" variant={myBallot.data?.choice === 'abstain' ? 'default' : 'outline'} onClick={() => cast.mutate('abstain')}>
              <MinusCircle className="h-4 w-4" /> Abstenerse
            </Button>
            {(isAdmin || new Date(vote.closes_at) < new Date()) && (
              <Button size="sm" variant="ghost" onClick={() => close.mutate()}>
                <Hammer className="h-4 w-4" /> Cerrar votación
              </Button>
            )}
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function NewGeneralVoteDialog({ groupId }: { groupId: string }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [form, setForm] = useState({ title: '', description: '', committee_only: 'false' })

  const create = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('create_vote', {
        p_group_id: groupId,
        p_subject_type: 'general',
        p_subject_id: null,
        p_title: form.title,
        p_description: form.description || null,
        p_payload: null,
        p_committee_only: form.committee_only === 'true',
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['votes', groupId] })
      toast.success('Votación abierta')
      setOpen(false)
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function onSubmit(e: FormEvent) { e.preventDefault(); create.mutate() }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button><Plus className="h-4 w-4" /> Nueva votación</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nueva votación general</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-3">
          <div className="space-y-1.5">
            <Label>Pregunta / título</Label>
            <Input value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} required />
          </div>
          <div className="space-y-1.5">
            <Label>Descripción</Label>
            <Textarea value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
          </div>
          <div className="space-y-1.5">
            <Label>¿Solo comité?</Label>
            <Select value={form.committee_only} onValueChange={(v) => setForm({ ...form, committee_only: v })}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="false">Todos los miembros</SelectItem>
                <SelectItem value="true">Solo comité</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <DialogFooter>
            <Button type="submit" disabled={create.isPending}>{create.isPending ? 'Abriendo…' : 'Abrir votación'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
