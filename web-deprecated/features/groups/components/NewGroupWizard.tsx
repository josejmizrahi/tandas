'use client'

import { useActionState, useState } from 'react'
import {
  Loader2, Utensils, PiggyBank, Spade, Trophy, BookOpen,
  Music, Heart, Plane, MoreHorizontal, type LucideIcon,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Checkbox } from '@/components/ui/checkbox'
import {
  Field, FieldDescription, FieldGroup, FieldLabel,
} from '@/components/ui/field'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { cn } from '@/lib/utils'
import { createGroup, type ActionResult } from '../actions'
import { GROUP_TYPES, getGroupTypePreset, type GroupTypeCode } from '../types'

const DAYS = [
  { v: '0', l: 'Domingo' }, { v: '1', l: 'Lunes' }, { v: '2', l: 'Martes' },
  { v: '3', l: 'Miércoles' }, { v: '4', l: 'Jueves' }, { v: '5', l: 'Viernes' }, { v: '6', l: 'Sábado' },
]

const ICON_MAP: Record<string, LucideIcon> = {
  Utensils, PiggyBank, Spade, Trophy, BookOpen, Music, Heart, Plane, MoreHorizontal,
}

export default function NewGroupWizard() {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(createGroup, null)

  const [step, setStep] = useState<1 | 2>(1)
  const [groupType, setGroupType] = useState<GroupTypeCode>('recurring_dinner')
  const preset = getGroupTypePreset(groupType)

  const [day, setDay] = useState<string>('')
  const [fundEnabled, setFundEnabled] = useState(preset.defaults.fund_enabled)

  function handlePickType(code: GroupTypeCode) {
    const newPreset = getGroupTypePreset(code)
    setGroupType(code)
    setFundEnabled(newPreset.defaults.fund_enabled)
    setStep(2)
  }

  if (step === 1) {
    return (
      <Card className="w-full max-w-md">
        <CardHeader className="space-y-2">
          <CardTitle>¿Qué tipo de grupo?</CardTitle>
          <CardDescription>
            Configuramos defaults razonables según el tipo. Puedes cambiarlos después.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ul className="space-y-2">
            {GROUP_TYPES.map((t) => {
              const Icon = ICON_MAP[t.icon] ?? MoreHorizontal
              return (
                <li key={t.code}>
                  <button
                    type="button"
                    onClick={() => handlePickType(t.code)}
                    className={cn(
                      'w-full flex items-start gap-3 text-left rounded-lg border p-3 transition-colors',
                      'hover:bg-accent hover:border-primary/50',
                    )}
                  >
                    <div className="flex size-9 items-center justify-center rounded-md bg-primary/10 text-primary shrink-0">
                      <Icon className="size-4" />
                    </div>
                    <div className="flex-1 space-y-0.5">
                      <p className="font-medium text-sm leading-tight">{t.label}</p>
                      <p className="text-xs text-muted-foreground">{t.description}</p>
                    </div>
                  </button>
                </li>
              )
            })}
          </ul>
        </CardContent>
      </Card>
    )
  }

  return (
    <Card className="w-full max-w-md">
      <CardHeader className="space-y-2">
        <CardTitle>Configuración inicial</CardTitle>
        <CardDescription>
          {preset.label} · vamos con los defaults para este tipo. Puedes cambiarlos después en Settings.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form action={action}>
          <input type="hidden" name="group_type" value={groupType} />

          <FieldGroup>
            <button
              type="button"
              onClick={() => setStep(1)}
              className="text-sm text-muted-foreground hover:text-foreground transition-colors -mb-2 self-start"
            >
              ← Cambiar tipo de grupo
            </button>

            <Field>
              <FieldLabel htmlFor="name">Nombre del grupo</FieldLabel>
              <Input
                id="name"
                name="name"
                placeholder="La Tanda de los Martes"
                required
                minLength={2}
                maxLength={60}
                autoFocus
              />
            </Field>

            <Field>
              <FieldLabel htmlFor="event_label">¿Cómo le dicen al evento?</FieldLabel>
              <Input
                id="event_label"
                name="event_label"
                defaultValue={preset.defaults.event_label}
                placeholder="Tanda / Cena / Reunión"
                key={preset.code}
              />
            </Field>

            <div className="grid grid-cols-2 gap-3">
              <Field>
                <FieldLabel htmlFor="default_day_of_week">Día de la semana</FieldLabel>
                <Select value={day} onValueChange={setDay}>
                  <SelectTrigger id="default_day_of_week">
                    <SelectValue placeholder="—" />
                  </SelectTrigger>
                  <SelectContent>
                    {DAYS.map((d) => (
                      <SelectItem key={d.v} value={d.v}>{d.l}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <input type="hidden" name="default_day_of_week" value={day} />
              </Field>
              <Field>
                <FieldLabel htmlFor="default_start_time">Hora</FieldLabel>
                <Input
                  id="default_start_time"
                  name="default_start_time"
                  type="time"
                  defaultValue="20:30"
                />
              </Field>
            </div>

            <Field>
              <div className="flex items-start gap-3 rounded-lg border p-3">
                <Checkbox
                  id="fund_enabled"
                  checked={fundEnabled}
                  onCheckedChange={(v) => setFundEnabled(v === true)}
                />
                <input type="hidden" name="fund_enabled" value={fundEnabled ? 'on' : 'off'} />
                <div className="space-y-1 leading-none flex-1">
                  <FieldLabel htmlFor="fund_enabled" className="text-sm font-medium cursor-pointer">
                    Activar fondo común
                  </FieldLabel>
                  <p className="text-xs text-muted-foreground">
                    Las multas pagadas se acumulan en una caja del grupo (para viajes, regalos, etc).
                  </p>
                </div>
              </div>
            </Field>

            {state && 'error' in state && (
              <FieldDescription className="text-destructive">
                {state.error._form?.[0]}
              </FieldDescription>
            )}

            <Field>
              <Button type="submit" disabled={pending} size="lg">
                {pending && <Loader2 className="size-4 animate-spin mr-2" />}
                {pending ? 'Creando…' : 'Crear grupo'}
              </Button>
            </Field>
          </FieldGroup>
        </form>
      </CardContent>
    </Card>
  )
}
