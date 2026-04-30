import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, Plus, Calendar, MapPin, Crown, Clock } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useGroup, useGroupId, useGroupMembers, useMyMembership } from '@/hooks/useGroupContext'
import { Button } from '@/components/ui/button'
import { Card, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { EmptyState } from '@/components/ui/empty-state'
import { formatDateTime } from '@/lib/utils'
import { EventDetail } from '@/components/event-detail'

export function GroupTandasPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const { data: group } = useGroup(groupId)
  const me = useMyMembership(groupId)
  const isAdmin = me?.role === 'admin'

  const events = useQuery({
    queryKey: ['events', groupId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('events')
        .select('*')
        .eq('group_id', groupId)
        .order('starts_at', { ascending: false })
      if (error) throw error
      return data
    },
  })

  const [openId, setOpenId] = useState<string | null>(null)

  if (!group) return null
  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-3">
        <Button variant="ghost" size="sm" onClick={() => navigate(`/grupos/${groupId}`)} className="-ml-3">
          <ArrowLeft className="h-4 w-4" /> Volver
        </Button>
        {isAdmin && <NewEventDialog groupId={groupId} eventLabel={group.event_label} />}
      </div>

      <div>
        <h1 className="text-2xl font-semibold">{group.event_label}s</h1>
        <p className="text-sm text-muted-foreground">Eventos, RSVP, llegadas y reglas automáticas.</p>
      </div>

      {events.isLoading ? (
        <div className="text-sm text-muted-foreground">Cargando…</div>
      ) : !events.data?.length ? (
        <EmptyState
          icon={<Calendar className="h-8 w-8" />}
          title={`Aún no hay ${group.event_label.toLowerCase()}s`}
          description={isAdmin ? 'Crea el primero para que el grupo confirme asistencia.' : 'Espera a que el admin programe el primero.'}
        />
      ) : (
        <div className="space-y-3">
          {events.data.map((e) => (
            <Card key={e.id} role="button" onClick={() => setOpenId(e.id)} className="cursor-pointer hover:bg-accent">
              <CardHeader className="flex-row items-center justify-between space-y-0">
                <div>
                  <CardTitle className="text-base">{e.title || `${group.event_label} #${e.cycle_number ?? '?'}`}</CardTitle>
                  <div className="mt-1 flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
                    <span className="inline-flex items-center gap-1"><Clock className="h-3.5 w-3.5" />{formatDateTime(e.starts_at)}</span>
                    {e.location && <span className="inline-flex items-center gap-1"><MapPin className="h-3.5 w-3.5" />{e.location}</span>}
                    {e.host_id && <HostBadge groupId={groupId} userId={e.host_id} />}
                  </div>
                </div>
                <StatusBadge status={e.status} />
              </CardHeader>
            </Card>
          ))}
        </div>
      )}

      <Dialog open={!!openId} onOpenChange={(o) => !o && setOpenId(null)}>
        <DialogContent className="max-w-2xl">
          {openId && <EventDetail eventId={openId} onClose={() => setOpenId(null)} />}
        </DialogContent>
      </Dialog>
    </div>
  )
}

function HostBadge({ groupId, userId }: { groupId: string; userId: string }) {
  const { data: members } = useGroupMembers(groupId)
  const m = members?.find((x) => x.user_id === userId)
  if (!m) return null
  return <span className="inline-flex items-center gap-1"><Crown className="h-3.5 w-3.5" />{m.profile?.display_name ?? 'Anfitrión'}</span>
}

function StatusBadge({ status }: { status: string }) {
  const variants: Record<string, 'default' | 'secondary' | 'success' | 'warning' | 'destructive'> = {
    scheduled: 'secondary',
    in_progress: 'warning',
    completed: 'success',
    cancelled: 'destructive',
  }
  const labels: Record<string, string> = {
    scheduled: 'Programado',
    in_progress: 'En curso',
    completed: 'Completado',
    cancelled: 'Cancelado',
  }
  return <Badge variant={variants[status] ?? 'default'}>{labels[status] ?? status}</Badge>
}

function NewEventDialog({ groupId, eventLabel }: { groupId: string; eventLabel: string }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [form, setForm] = useState({
    starts_at: nextDateAt('20:30'),
    location: '',
    title: '',
    rsvp_deadline: '',
    host_id: 'auto',
  })
  const { data: members } = useGroupMembers(groupId)

  const create = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('create_event', {
        p_group_id: groupId,
        p_starts_at: new Date(form.starts_at).toISOString(),
        p_ends_at: null,
        p_location: form.location || null,
        p_title: form.title || null,
        p_host_id: form.host_id === 'auto' ? null : form.host_id,
        p_cycle_number: null,
        p_rsvp_deadline: form.rsvp_deadline ? new Date(form.rsvp_deadline).toISOString() : null,
      })
      if (error) throw error
      return data
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['events', groupId] })
      toast.success('Evento creado')
      setOpen(false)
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
        <Button><Plus className="h-4 w-4" /> Nuevo {eventLabel.toLowerCase()}</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nuevo {eventLabel.toLowerCase()}</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-3">
          <div className="space-y-1.5">
            <Label>Fecha y hora</Label>
            <Input type="datetime-local" value={form.starts_at} onChange={(e) => setForm({ ...form, starts_at: e.target.value })} required />
          </div>
          <div className="space-y-1.5">
            <Label>Deadline de confirmación (opcional)</Label>
            <Input type="datetime-local" value={form.rsvp_deadline} onChange={(e) => setForm({ ...form, rsvp_deadline: e.target.value })} />
          </div>
          <div className="space-y-1.5">
            <Label>Lugar</Label>
            <Input value={form.location} onChange={(e) => setForm({ ...form, location: e.target.value })} placeholder="Casa de…" />
          </div>
          <div className="space-y-1.5">
            <Label>Anfitrión</Label>
            <Select value={form.host_id} onValueChange={(v) => setForm({ ...form, host_id: v })}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="auto">Automático (siguiente en rotación)</SelectItem>
                {members?.map((m) => (
                  <SelectItem key={m.user_id} value={m.user_id}>{m.profile?.display_name ?? m.user_id}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>Notas (opcional)</Label>
            <Textarea value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} placeholder="Título del evento" />
          </div>
          <DialogFooter>
            <Button type="submit" disabled={create.isPending}>{create.isPending ? 'Creando…' : 'Crear'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

function nextDateAt(timeHHMM: string): string {
  const d = new Date()
  d.setDate(d.getDate() + ((9 - d.getDay()) % 7 || 7)) // next Tuesday-ish
  const [h, m] = timeHHMM.split(':').map(Number)
  d.setHours(h, m, 0, 0)
  return d.toISOString().slice(0, 16)
}
