import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'

export function NewGroupPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [form, setForm] = useState({
    name: '',
    description: '',
    event_label: 'Tanda',
    currency: 'MXN',
    timezone: 'America/Mexico_City',
    default_day_of_week: '2', // Tuesday
    default_start_time: '20:30',
    default_location: '',
    voting_threshold: '0.5',
    voting_quorum: '0.5',
    fund_enabled: 'true',
  })

  const createGroup = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('create_group_with_admin', {
        p_name: form.name,
        p_description: form.description || null,
        p_event_label: form.event_label,
        p_currency: form.currency,
        p_timezone: form.timezone,
        p_default_day: form.default_day_of_week ? Number(form.default_day_of_week) : null,
        p_default_time: form.default_start_time || null,
        p_default_location: form.default_location || null,
        p_voting_threshold: Number(form.voting_threshold),
        p_voting_quorum: Number(form.voting_quorum),
        p_fund_enabled: form.fund_enabled === 'true',
      })
      if (error) throw error
      return data
    },
    onSuccess: (group) => {
      qc.invalidateQueries({ queryKey: ['groups'] })
      toast.success('Grupo creado')
      navigate(`/grupos/${group.id}`)
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function set<K extends keyof typeof form>(k: K, v: string) {
    setForm((s) => ({ ...s, [k]: v }))
  }

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!form.name.trim()) return
    createGroup.mutate()
  }

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      <Button variant="ghost" size="sm" onClick={() => navigate('/grupos')}>
        <ArrowLeft className="h-4 w-4" /> Volver
      </Button>
      <Card>
        <CardHeader>
          <CardTitle>Nuevo grupo</CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={onSubmit} className="space-y-4">
            <Field label="Nombre del grupo">
              <Input
                value={form.name}
                onChange={(e) => set('name', e.target.value)}
                placeholder="La Tanda de los martes"
                required
              />
            </Field>
            <Field label="Descripción (opcional)">
              <Textarea
                value={form.description}
                onChange={(e) => set('description', e.target.value)}
                placeholder="Cena semanal entre amigos. Reglamento estilo casa de Moshe."
              />
            </Field>

            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Cómo le llaman al evento">
                <Input value={form.event_label} onChange={(e) => set('event_label', e.target.value)} placeholder="Tanda / Cena / Reunión" />
              </Field>
              <Field label="Moneda">
                <Input value={form.currency} onChange={(e) => set('currency', e.target.value)} />
              </Field>
            </div>

            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Día de la semana">
                <Select value={form.default_day_of_week} onValueChange={(v) => set('default_day_of_week', v)}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="0">Domingo</SelectItem>
                    <SelectItem value="1">Lunes</SelectItem>
                    <SelectItem value="2">Martes</SelectItem>
                    <SelectItem value="3">Miércoles</SelectItem>
                    <SelectItem value="4">Jueves</SelectItem>
                    <SelectItem value="5">Viernes</SelectItem>
                    <SelectItem value="6">Sábado</SelectItem>
                  </SelectContent>
                </Select>
              </Field>
              <Field label="Hora de inicio">
                <Input type="time" value={form.default_start_time} onChange={(e) => set('default_start_time', e.target.value)} />
              </Field>
              <Field label="Lugar (default)">
                <Input value={form.default_location} onChange={(e) => set('default_location', e.target.value)} placeholder="Casa del anfitrión" />
              </Field>
            </div>

            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Mayoría para aprobar">
                <Input type="number" step="0.05" min="0.05" max="1" value={form.voting_threshold} onChange={(e) => set('voting_threshold', e.target.value)} />
              </Field>
              <Field label="Quórum mínimo">
                <Input type="number" step="0.05" min="0.05" max="1" value={form.voting_quorum} onChange={(e) => set('voting_quorum', e.target.value)} />
              </Field>
              <Field label="Fondo (multas)">
                <Select value={form.fund_enabled} onValueChange={(v) => set('fund_enabled', v)}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="true">Activado</SelectItem>
                    <SelectItem value="false">No usar fondo</SelectItem>
                  </SelectContent>
                </Select>
              </Field>
            </div>

            <div className="flex justify-end pt-2">
              <Button type="submit" disabled={createGroup.isPending}>
                {createGroup.isPending ? 'Creando…' : 'Crear grupo'}
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
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
