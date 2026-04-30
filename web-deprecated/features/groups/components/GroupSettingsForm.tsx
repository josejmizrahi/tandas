'use client'

import { useActionState, useState } from 'react'
import { Loader2, Check } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Checkbox } from '@/components/ui/checkbox'
import {
  Field, FieldDescription, FieldGroup, FieldLabel,
} from '@/components/ui/field'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { updateGroupSettings, type ActionResult } from '../actions'

const DAYS = [
  { v: '0', l: 'Domingo' }, { v: '1', l: 'Lunes' }, { v: '2', l: 'Martes' },
  { v: '3', l: 'Miércoles' }, { v: '4', l: 'Jueves' }, { v: '5', l: 'Viernes' }, { v: '6', l: 'Sábado' },
]

type GroupRow = {
  id: string
  name: string
  event_label: string
  default_day_of_week: number | null
  default_start_time: string | null
  default_location: string | null
  voting_threshold: number
  voting_quorum: number
  vote_duration_hours: number
  no_show_grace_minutes: number
  grace_period_events: number
  monthly_fine_cap_mxn: number | null
  fund_enabled: boolean
  committee_required_for_appeals: boolean
  block_unpaid_attendance: boolean
  rotation_enabled: boolean
}

export default function GroupSettingsForm({ group }: { group: GroupRow }) {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(updateGroupSettings, null)
  const [day, setDay] = useState<string>(group.default_day_of_week?.toString() ?? '')
  const [fund, setFund] = useState(group.fund_enabled)
  const [committee, setCommittee] = useState(group.committee_required_for_appeals)
  const [block, setBlock] = useState(group.block_unpaid_attendance)
  const [rotation, setRotation] = useState(group.rotation_enabled)

  const saved = state !== null && 'ok' in state && state.ok

  return (
    <form action={action}>
      <input type="hidden" name="group_id" value={group.id} />
      <input type="hidden" name="default_day_of_week" value={day} />
      <input type="hidden" name="fund_enabled" value={fund ? 'on' : 'off'} />
      <input type="hidden" name="committee_required_for_appeals" value={committee ? 'on' : 'off'} />
      <input type="hidden" name="block_unpaid_attendance" value={block ? 'on' : 'off'} />
      <input type="hidden" name="rotation_enabled" value={rotation ? 'on' : 'off'} />

      <FieldGroup>
        <SectionHeader title="Lo básico" />

        <Field>
          <FieldLabel htmlFor="name">Nombre del grupo</FieldLabel>
          <Input id="name" name="name" defaultValue={group.name} required minLength={2} maxLength={60} />
        </Field>

        <Field>
          <FieldLabel htmlFor="event_label">Cómo le dicen al evento</FieldLabel>
          <Input id="event_label" name="event_label" defaultValue={group.event_label} required minLength={2} maxLength={30} />
        </Field>

        <div className="grid grid-cols-2 gap-3">
          <Field>
            <FieldLabel htmlFor="day-select">Día</FieldLabel>
            <Select value={day} onValueChange={setDay}>
              <SelectTrigger id="day-select">
                <SelectValue placeholder="—" />
              </SelectTrigger>
              <SelectContent>
                {DAYS.map((d) => (
                  <SelectItem key={d.v} value={d.v}>{d.l}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
          <Field>
            <FieldLabel htmlFor="default_start_time">Hora</FieldLabel>
            <Input
              id="default_start_time"
              name="default_start_time"
              type="time"
              defaultValue={group.default_start_time ?? '20:30'}
            />
          </Field>
        </div>

        <Field>
          <FieldLabel htmlFor="default_location">Lugar default (opcional)</FieldLabel>
          <Input
            id="default_location"
            name="default_location"
            defaultValue={group.default_location ?? ''}
            maxLength={200}
            placeholder="Casa de Eduardo, Polanco"
          />
        </Field>

        <SectionHeader title="Anti-tiranía" />

        <Field>
          <FieldLabel htmlFor="grace_period_events">Período de gracia para nuevos miembros</FieldLabel>
          <Input
            id="grace_period_events"
            name="grace_period_events"
            type="number"
            min={0}
            max={50}
            defaultValue={group.grace_period_events}
          />
          <FieldDescription>
            Las primeras N {group.event_label.toLowerCase()}s de un miembro nuevo no generan multas automáticas.
            Default: 3.
          </FieldDescription>
        </Field>

        <Field>
          <FieldLabel htmlFor="monthly_fine_cap_mxn">Tope mensual de multas (MXN)</FieldLabel>
          <Input
            id="monthly_fine_cap_mxn"
            name="monthly_fine_cap_mxn"
            type="number"
            min={0}
            step={50}
            placeholder="Sin tope"
            defaultValue={group.monthly_fine_cap_mxn ?? ''}
          />
          <FieldDescription>
            Después de este monto en multas automáticas en el mes, no se generan más para ese miembro.
            Vacío = sin tope.
          </FieldDescription>
        </Field>

        <SectionHeader title="Votaciones" />

        <div className="grid grid-cols-2 gap-3">
          <Field>
            <FieldLabel htmlFor="voting_threshold">Umbral para pasar (%)</FieldLabel>
            <Input
              id="voting_threshold"
              name="voting_threshold"
              type="number"
              step={0.05}
              min={0.01}
              max={1}
              defaultValue={group.voting_threshold}
            />
            <FieldDescription>0.5 = 50% de Sí</FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="voting_quorum">Quórum mínimo (%)</FieldLabel>
            <Input
              id="voting_quorum"
              name="voting_quorum"
              type="number"
              step={0.05}
              min={0.01}
              max={1}
              defaultValue={group.voting_quorum}
            />
            <FieldDescription>0.5 = mitad participa</FieldDescription>
          </Field>
        </div>

        <Field>
          <FieldLabel htmlFor="vote_duration_hours">Duración de cada votación (horas)</FieldLabel>
          <Input
            id="vote_duration_hours"
            name="vote_duration_hours"
            type="number"
            min={1}
            max={720}
            defaultValue={group.vote_duration_hours}
          />
        </Field>

        <SectionHeader title="Eventos" />

        <Field>
          <FieldLabel htmlFor="no_show_grace_minutes">Margen para no-show (min)</FieldLabel>
          <Input
            id="no_show_grace_minutes"
            name="no_show_grace_minutes"
            type="number"
            min={5}
            max={720}
            defaultValue={group.no_show_grace_minutes}
          />
          <FieldDescription>
            Después de este margen post hora-de-inicio, los pendientes se marcan como no-show automáticamente.
          </FieldDescription>
        </Field>

        <ToggleField
          id="rotation_enabled"
          label="Anfitrión rotativo"
          desc="Cada nuevo evento se le asigna al siguiente miembro en orden."
          checked={rotation}
          onChange={setRotation}
        />

        <ToggleField
          id="fund_enabled"
          label="Fondo común"
          desc="Las multas pagadas se acumulan en una caja del grupo (viajes, regalos, etc)."
          checked={fund}
          onChange={setFund}
        />

        <ToggleField
          id="committee_required_for_appeals"
          label="Solo el comité vota apelaciones"
          desc="Si está apagado, todo el grupo vota las apelaciones de multas."
          checked={committee}
          onChange={setCommittee}
        />

        <ToggleField
          id="block_unpaid_attendance"
          label="Bloquear con multas sin pagar"
          desc="Miembros con multas pendientes no pueden RSVP al próximo evento."
          checked={block}
          onChange={setBlock}
        />

        {state && 'error' in state && (
          <FieldDescription className="text-destructive">
            {state.error._form?.[0]}
          </FieldDescription>
        )}

        {saved && (
          <FieldDescription className="text-emerald-600 flex items-center gap-1">
            <Check className="size-4" /> Cambios guardados.
          </FieldDescription>
        )}

        <Field>
          <Button type="submit" disabled={pending} size="lg">
            {pending && <Loader2 className="size-4 animate-spin mr-2" />}
            {pending ? 'Guardando…' : 'Guardar cambios'}
          </Button>
        </Field>
      </FieldGroup>
    </form>
  )
}

function SectionHeader({ title }: { title: string }) {
  return (
    <div className="pt-2">
      <p className="text-sm font-semibold text-muted-foreground uppercase tracking-wide">{title}</p>
    </div>
  )
}

function ToggleField({
  id, label, desc, checked, onChange,
}: { id: string; label: string; desc: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="flex items-start gap-3 rounded-lg border p-3">
      <Checkbox
        id={id}
        checked={checked}
        onCheckedChange={(v) => onChange(v === true)}
      />
      <div className="space-y-1 leading-none flex-1">
        <FieldLabel htmlFor={id} className="text-sm font-medium cursor-pointer">{label}</FieldLabel>
        <p className="text-xs text-muted-foreground">{desc}</p>
      </div>
    </div>
  )
}
