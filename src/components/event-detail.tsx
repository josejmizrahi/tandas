import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Check, Clock, X, AlarmClock, Sparkles } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useGroup, useGroupMembers, useMyMembership } from '@/hooks/useGroupContext'
import { useAuth } from '@/app/providers/AuthProvider'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { formatDateTime, initials } from '@/lib/utils'

const RSVP_LABELS: Record<string, string> = {
  pending: 'Sin responder',
  going: 'Voy',
  maybe: 'Tal vez',
  declined: 'No voy',
}

export function EventDetail({ eventId, onClose }: { eventId: string; onClose: () => void }) {
  const qc = useQueryClient()
  const { user } = useAuth()

  const { data: event } = useQuery({
    queryKey: ['event', eventId],
    queryFn: async () => {
      const { data, error } = await supabase.from('events').select('*').eq('id', eventId).single()
      if (error) throw error
      return data
    },
  })

  const groupId = event?.group_id ?? ''
  const { data: group } = useGroup(groupId)
  const { data: members } = useGroupMembers(groupId)
  const me = useMyMembership(groupId)
  const isAdmin = me?.role === 'admin'

  const attendance = useQuery({
    queryKey: ['attendance', eventId],
    enabled: !!event,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('event_attendance')
        .select('*')
        .eq('event_id', eventId)
      if (error) throw error
      return data
    },
  })

  const rsvp = useMutation({
    mutationFn: async (status: 'going' | 'maybe' | 'declined') => {
      if (!user) throw new Error('no auth')
      const { error } = await supabase
        .from('event_attendance')
        .upsert(
          {
            event_id: eventId,
            user_id: user.id,
            rsvp_status: status,
            rsvp_at: new Date().toISOString(),
          },
          { onConflict: 'event_id,user_id' }
        )
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['attendance', eventId] }),
    onError: (e: Error) => toast.error(e.message),
  })

  const checkIn = useMutation({
    mutationFn: async (userId: string) => {
      const { error } = await supabase.rpc('check_in_attendee', {
        p_event_id: eventId,
        p_user_id: userId,
        p_arrived_at: new Date().toISOString(),
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['attendance', eventId] })
      toast.success('Llegada registrada')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const markNoShow = useMutation({
    mutationFn: async (userId: string) => {
      const { error } = await supabase
        .from('event_attendance')
        .update({ no_show: true, marked_by: user?.id })
        .eq('event_id', eventId)
        .eq('user_id', userId)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['attendance', eventId] }),
    onError: (e: Error) => toast.error(e.message),
  })

  const cancelSameDay = useMutation({
    mutationFn: async () => {
      if (!user) return
      const { error } = await supabase
        .from('event_attendance')
        .update({ cancelled_same_day: true, rsvp_status: 'declined' })
        .eq('event_id', eventId)
        .eq('user_id', user.id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['attendance', eventId] }),
    onError: (e: Error) => toast.error(e.message),
  })

  const evaluate = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('evaluate_event_rules', { p_event_id: eventId })
      if (error) throw error
      return data
    },
    onSuccess: (count) => {
      qc.invalidateQueries({ queryKey: ['event', eventId] })
      qc.invalidateQueries({ queryKey: ['fines', groupId] })
      toast.success(`Reglas evaluadas. ${count} multa${count === 1 ? '' : 's'} generada${count === 1 ? '' : 's'}.`)
      onClose()
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const [confirmEval, setConfirmEval] = useState(false)

  if (!event || !group) return <div className="text-sm text-muted-foreground">Cargando…</div>

  const myAtt = attendance.data?.find((a) => a.user_id === user?.id)

  return (
    <div className="space-y-4">
      <div>
        <div className="text-xs text-muted-foreground">{group.event_label}</div>
        <h2 className="text-lg font-semibold">{event.title || `${group.event_label} #${event.cycle_number ?? '?'}`}</h2>
        <div className="mt-1 text-sm text-muted-foreground">
          <Clock className="-mt-0.5 mr-1 inline h-4 w-4" />
          {formatDateTime(event.starts_at)}
          {event.location && <> · {event.location}</>}
        </div>
        {event.rsvp_deadline && (
          <div className="mt-1 text-xs text-muted-foreground">
            Confirmar antes de: {formatDateTime(event.rsvp_deadline)}
          </div>
        )}
      </div>

      <div className="rounded-lg border bg-muted/40 p-3">
        <div className="mb-2 text-sm font-medium">Tu RSVP</div>
        <div className="flex flex-wrap gap-2">
          <Button size="sm" variant={myAtt?.rsvp_status === 'going' ? 'default' : 'outline'} onClick={() => rsvp.mutate('going')}>
            <Check className="h-4 w-4" /> Voy
          </Button>
          <Button size="sm" variant={myAtt?.rsvp_status === 'maybe' ? 'default' : 'outline'} onClick={() => rsvp.mutate('maybe')}>
            ? Tal vez
          </Button>
          <Button size="sm" variant={myAtt?.rsvp_status === 'declined' ? 'default' : 'outline'} onClick={() => rsvp.mutate('declined')}>
            <X className="h-4 w-4" /> No voy
          </Button>
          {myAtt?.rsvp_status !== 'declined' && (
            <Button size="sm" variant="ghost" onClick={() => cancelSameDay.mutate()}>
              Cancelar (mismo día)
            </Button>
          )}
        </div>
        {myAtt?.arrived_at ? (
          <div className="mt-2 text-xs text-muted-foreground">Llegaste a las {new Date(myAtt.arrived_at).toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' })}.</div>
        ) : (
          <Button size="sm" variant="secondary" className="mt-2" onClick={() => user && checkIn.mutate(user.id)}>
            <AlarmClock className="h-4 w-4" /> Marcar mi llegada ahora
          </Button>
        )}
      </div>

      <div>
        <div className="mb-2 flex items-center justify-between">
          <h3 className="text-sm font-medium">Asistencia ({attendance.data?.length ?? 0})</h3>
          {isAdmin && event.status !== 'completed' && (
            <Button size="sm" onClick={() => setConfirmEval(true)}>
              <Sparkles className="h-4 w-4" /> Cerrar y evaluar reglas
            </Button>
          )}
        </div>
        <div className="space-y-1.5">
          {attendance.data?.map((a) => {
            const m = members?.find((x) => x.user_id === a.user_id)
            const name = m?.profile?.display_name ?? 'Miembro'
            return (
              <div key={a.id} className="flex items-center justify-between rounded-md border p-2">
                <div className="flex min-w-0 items-center gap-2">
                  <Avatar className="h-7 w-7"><AvatarFallback>{initials(name)}</AvatarFallback></Avatar>
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium">{name}</div>
                    <div className="truncate text-xs text-muted-foreground">
                      {RSVP_LABELS[a.rsvp_status] ?? a.rsvp_status}
                      {a.cancelled_same_day && ' · canceló'}
                      {a.no_show && ' · no-show'}
                      {a.arrived_at && ` · llegó ${new Date(a.arrived_at).toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' })}`}
                    </div>
                  </div>
                </div>
                {isAdmin && event.status !== 'completed' && (
                  <div className="flex shrink-0 items-center gap-1">
                    {!a.arrived_at && (
                      <Button size="sm" variant="outline" onClick={() => checkIn.mutate(a.user_id)}>
                        Llegó
                      </Button>
                    )}
                    {!a.no_show && (
                      <Button size="sm" variant="ghost" onClick={() => markNoShow.mutate(a.user_id)}>
                        No-show
                      </Button>
                    )}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {event.status === 'completed' && (
        <div className="rounded-md border border-emerald-500/30 bg-emerald-50 p-3 text-sm dark:bg-emerald-950/30">
          Reglas evaluadas el {event.rules_evaluated_at && formatDateTime(event.rules_evaluated_at)}.
          Las multas generadas aparecen en la sección Multas.
        </div>
      )}

      {confirmEval && (
        <div className="rounded-md border border-amber-500/30 bg-amber-50 p-3 text-sm dark:bg-amber-950/30">
          <div className="mb-2 font-medium">¿Cerrar y evaluar reglas?</div>
          <p className="mb-2 text-xs text-muted-foreground">
            Se generarán multas automáticas según las reglas activas (llegadas tarde, no-shows, etc.).
            Esta acción solo puede correrse una vez.
          </p>
          <div className="flex gap-2">
            <Button size="sm" onClick={() => evaluate.mutate()} disabled={evaluate.isPending}>
              {evaluate.isPending ? 'Evaluando…' : 'Sí, evaluar'}
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setConfirmEval(false)}>Cancelar</Button>
          </div>
        </div>
      )}

      <Badge variant="outline">
        {event.status === 'completed' ? 'Completado' : event.status === 'cancelled' ? 'Cancelado' : 'Programado'}
      </Badge>
    </div>
  )
}
