import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, Plus, Vote, Power, Archive } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useGroupId, useGroupMembers, useMyMembership } from '@/hooks/useGroupContext'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { EmptyState } from '@/components/ui/empty-state'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { RULE_PRESETS, TRIGGER_LABELS, describeTrigger, type RulePreset } from '@/lib/rule-presets'
import type { Database, Json } from '@/lib/database.types'

type Rule = Database['public']['Tables']['rules']['Row']

export function GroupRulesPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const me = useMyMembership(groupId)
  const isAdmin = me?.role === 'admin'

  const rules = useQuery({
    queryKey: ['rules', groupId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rules')
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
        <NewRuleDialog groupId={groupId} />
      </div>

      <div>
        <h1 className="text-2xl font-semibold">Reglas</h1>
        <p className="text-sm text-muted-foreground">
          Las reglas activas se evalúan automáticamente al cerrar cada evento. Cualquier miembro puede proponer una nueva.
        </p>
      </div>

      {rules.isLoading ? (
        <div className="text-sm text-muted-foreground">Cargando…</div>
      ) : !rules.data?.length ? (
        <EmptyState
          title="Aún no hay reglas"
          description="Empieza con un preset (llegadas tarde, no confirmar, no-show, anfitrión) o crea una propuesta personalizada."
          action={<NewRuleDialog groupId={groupId} buttonLabel="Crear primera regla" />}
        />
      ) : (
        <div className="space-y-3">
          {rules.data.map((r) => (
            <RuleCard key={r.id} rule={r} groupId={groupId} isAdmin={isAdmin} />
          ))}
        </div>
      )}
    </div>
  )
}

function RuleCard({ rule, groupId, isAdmin }: { rule: Rule; groupId: string; isAdmin: boolean }) {
  const qc = useQueryClient()
  const trigger = rule.trigger as { type: string; params: Record<string, unknown> }
  const exceptions = (rule.exceptions as Array<{ user_id: string; reason?: string }>) ?? []
  const { data: members } = useGroupMembers(groupId)

  const toggle = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('rules').update({ enabled: !rule.enabled }).eq('id', rule.id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['rules', groupId] })
      toast.success(rule.enabled ? 'Regla deshabilitada' : 'Regla activada')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  const archive = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('rules').update({ status: 'archived', enabled: false }).eq('id', rule.id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['rules', groupId] })
      toast.success('Regla archivada')
    },
  })

  const proposeRepeal = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('create_vote', {
        p_group_id: groupId,
        p_subject_type: 'rule_repeal',
        p_subject_id: rule.id,
        p_title: `Derogar: ${rule.title}`,
        p_description: 'Propuesta de derogar esta regla.',
        p_payload: null,
        p_committee_only: false,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['votes', groupId] })
      toast.success('Votación de derogación abierta')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  return (
    <Card>
      <CardHeader>
        <div className="flex items-start justify-between gap-2">
          <div>
            <CardTitle className="text-base">{rule.title}</CardTitle>
            <CardDescription>{rule.description ?? describeTrigger(trigger as never)}</CardDescription>
          </div>
          <div className="flex shrink-0 flex-wrap gap-1">
            <Badge variant="outline">{TRIGGER_LABELS[trigger.type as keyof typeof TRIGGER_LABELS] ?? trigger.type}</Badge>
            <Badge variant={rule.status === 'active' && rule.enabled ? 'success' : rule.status === 'proposed' ? 'warning' : 'secondary'}>
              {rule.status === 'proposed' ? 'En votación' : rule.enabled ? 'Activa' : rule.status === 'archived' ? 'Archivada' : 'Inactiva'}
            </Badge>
          </div>
        </div>
      </CardHeader>
      <CardContent className="space-y-2 text-sm">
        <div className="text-muted-foreground">{describeTrigger(trigger as never)}</div>
        {exceptions.length > 0 && (
          <div className="text-xs">
            <span className="font-medium">Excepciones:</span>{' '}
            {exceptions
              .map((ex) => members?.find((m) => m.user_id === ex.user_id)?.profile?.display_name ?? '?')
              .join(', ')}
          </div>
        )}
        <div className="flex flex-wrap gap-2 pt-2">
          {isAdmin && rule.status === 'active' && (
            <>
              <Button size="sm" variant="outline" onClick={() => toggle.mutate()}>
                <Power className="h-4 w-4" /> {rule.enabled ? 'Deshabilitar' : 'Activar'}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => archive.mutate()}>
                <Archive className="h-4 w-4" /> Archivar
              </Button>
            </>
          )}
          {rule.status === 'active' && (
            <Button size="sm" variant="ghost" onClick={() => proposeRepeal.mutate()}>
              <Vote className="h-4 w-4" /> Proponer derogar
            </Button>
          )}
        </div>
      </CardContent>
    </Card>
  )
}

function NewRuleDialog({ groupId, buttonLabel = 'Proponer regla' }: { groupId: string; buttonLabel?: string }) {
  const qc = useQueryClient()
  const { data: members } = useGroupMembers(groupId)
  const me = useMyMembership(groupId)
  const isAdmin = me?.role === 'admin'

  const [open, setOpen] = useState(false)
  const [presetKey, setPresetKey] = useState<string>(RULE_PRESETS[0].key)
  const preset: RulePreset = RULE_PRESETS.find((r) => r.key === presetKey) ?? RULE_PRESETS[0]
  const [title, setTitle] = useState(preset.title)
  const [description, setDescription] = useState(preset.description)
  const [params, setParams] = useState<Record<string, unknown>>(preset.trigger.params as Record<string, unknown>)
  const [excepted, setExcepted] = useState<string[]>([])
  const [activateImmediately, setActivateImmediately] = useState(isAdmin ? 'true' : 'false')

  function onPresetChange(k: string) {
    setPresetKey(k)
    const p = RULE_PRESETS.find((r) => r.key === k)!
    setTitle(p.title)
    setDescription(p.description)
    setParams(p.trigger.params as Record<string, unknown>)
  }

  const submit = useMutation({
    mutationFn: async () => {
      const trigger = { type: preset.trigger.type, params } as unknown as Json
      const exceptions = excepted.map((uid) => ({ user_id: uid })) as unknown as Json
      const action = { type: 'fine' } as unknown as Json
      if (activateImmediately === 'true' && isAdmin) {
        const { error } = await supabase.from('rules').insert({
          group_id: groupId,
          title,
          description,
          trigger,
          action,
          exceptions,
          status: 'active',
          enabled: true,
        })
        if (error) throw error
        return 'activated'
      }
      const { error } = await supabase.rpc('propose_rule', {
        p_group_id: groupId,
        p_title: title,
        p_description: description,
        p_trigger: trigger,
        p_action: action,
        p_exceptions: exceptions,
        p_committee_only: false,
      })
      if (error) throw error
      return 'proposed'
    },
    onSuccess: (kind) => {
      qc.invalidateQueries({ queryKey: ['rules', groupId] })
      qc.invalidateQueries({ queryKey: ['votes', groupId] })
      toast.success(kind === 'activated' ? 'Regla activada' : 'Propuesta enviada a votación')
      setOpen(false)
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    submit.mutate()
  }

  function setParam(k: string, v: unknown) {
    setParams((p) => ({ ...p, [k]: v }))
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button><Plus className="h-4 w-4" /> {buttonLabel}</Button>
      </DialogTrigger>
      <DialogContent className="max-w-xl">
        <DialogHeader>
          <DialogTitle>Nueva regla</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-3">
          <div className="space-y-1.5">
            <Label>Tipo (preset)</Label>
            <Select value={presetKey} onValueChange={onPresetChange}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                {RULE_PRESETS.map((p) => (
                  <SelectItem key={p.key} value={p.key}>{p.title}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1.5">
            <Label>Título</Label>
            <Input value={title} onChange={(e) => setTitle(e.target.value)} required />
          </div>
          <div className="space-y-1.5">
            <Label>Descripción</Label>
            <Textarea value={description} onChange={(e) => setDescription(e.target.value)} />
          </div>

          {/* Parameter editors per preset */}
          {preset.trigger.type === 'late_arrival' && (
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Hora de corte (HH:MM)">
                <Input value={(params.start_threshold_time as string) ?? ''} onChange={(e) => setParam('start_threshold_time', e.target.value)} placeholder="21:00" />
              </Field>
              <Field label="Multa base">
                <Input type="number" value={(params.base_amount as number) ?? 0} onChange={(e) => setParam('base_amount', Number(e.target.value))} />
              </Field>
              <Field label="Cada N minutos">
                <Input type="number" value={(params.step_minutes as number) ?? 30} onChange={(e) => setParam('step_minutes', Number(e.target.value))} />
              </Field>
              <Field label="Incremento por escalón">
                <Input type="number" value={(params.step_increment as number) ?? 50} onChange={(e) => setParam('step_increment', Number(e.target.value))} />
              </Field>
            </div>
          )}
          {preset.trigger.type === 'no_confirmation' && (
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Horas antes (deadline)">
                <Input type="number" value={(params.deadline_offset_hours as number) ?? 24} onChange={(e) => setParam('deadline_offset_hours', Number(e.target.value))} />
              </Field>
              <Field label="Multa">
                <Input type="number" value={(params.fixed_amount as number) ?? 0} onChange={(e) => setParam('fixed_amount', Number(e.target.value))} />
              </Field>
            </div>
          )}
          {(preset.trigger.type === 'same_day_cancel' || preset.trigger.type === 'no_show') && (
            <Field label="Multa">
              <Input type="number" value={(params.fixed_amount as number) ?? 0} onChange={(e) => setParam('fixed_amount', Number(e.target.value))} />
            </Field>
          )}
          {(preset.trigger.type === 'host_skip_no_notice' || preset.trigger.type === 'host_food_late') && (
            <div className="grid gap-3 sm:grid-cols-2">
              {preset.trigger.type === 'host_skip_no_notice' ? (
                <>
                  <Field label="Día deadline">
                    <Input value={(params.deadline_day as string) ?? ''} onChange={(e) => setParam('deadline_day', e.target.value)} placeholder="sunday" />
                  </Field>
                  <Field label="Hora deadline">
                    <Input value={(params.deadline_time as string) ?? ''} onChange={(e) => setParam('deadline_time', e.target.value)} placeholder="18:00" />
                  </Field>
                </>
              ) : (
                <Field label="Hora límite (comida)">
                  <Input value={(params.deadline_time as string) ?? ''} onChange={(e) => setParam('deadline_time', e.target.value)} placeholder="20:45" />
                </Field>
              )}
              <Field label="Multa">
                <Input type="number" value={(params.fixed_amount as number) ?? 0} onChange={(e) => setParam('fixed_amount', Number(e.target.value))} />
              </Field>
            </div>
          )}

          <div className="space-y-1.5">
            <Label>Excepciones (miembros que NO pagan esta regla)</Label>
            <div className="flex flex-wrap gap-2">
              {members?.map((m) => (
                <button
                  key={m.user_id}
                  type="button"
                  onClick={() => setExcepted((s) => (s.includes(m.user_id) ? s.filter((x) => x !== m.user_id) : [...s, m.user_id]))}
                  className={`rounded-full border px-3 py-1 text-xs transition-colors ${excepted.includes(m.user_id) ? 'bg-primary text-primary-foreground' : 'bg-background'}`}
                >
                  {m.profile?.display_name ?? 'miembro'}
                </button>
              ))}
            </div>
          </div>

          {isAdmin && (
            <div className="space-y-1.5">
              <Label>Activación</Label>
              <Select value={activateImmediately} onValueChange={setActivateImmediately}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="true">Activar ahora (admin)</SelectItem>
                  <SelectItem value="false">Mandar a votación</SelectItem>
                </SelectContent>
              </Select>
            </div>
          )}

          <DialogFooter>
            <Button type="submit" disabled={submit.isPending}>
              {submit.isPending ? 'Guardando…' : activateImmediately === 'true' && isAdmin ? 'Activar regla' : 'Proponer'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <Label>{label}</Label>
      {children}
    </div>
  )
}
