'use client'

import { useActionState, useState } from 'react'
import { Loader2 } from 'lucide-react'
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
import { createGroup, type ActionResult } from '../actions'

const DAYS = [
  { v: '0', l: 'Domingo' }, { v: '1', l: 'Lunes' }, { v: '2', l: 'Martes' },
  { v: '3', l: 'Miércoles' }, { v: '4', l: 'Jueves' }, { v: '5', l: 'Viernes' }, { v: '6', l: 'Sábado' },
]

export default function NewGroupWizard() {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(createGroup, null)
  const [day, setDay] = useState<string>('')
  const [fundEnabled, setFundEnabled] = useState(true)

  return (
    <Card className="w-full max-w-md">
      <CardHeader className="space-y-2">
        <CardTitle>Nuevo grupo</CardTitle>
        <CardDescription>
          Lo básico para empezar. Las reglas y umbrales se configuran después en Settings.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form action={action}>
          <FieldGroup>
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
                defaultValue="Tanda"
                placeholder="Tanda / Cena / Reunión"
              />
              <FieldDescription>
                Aparecerá en la app como &ldquo;Próxima {`{nombre}`}&rdquo;.
              </FieldDescription>
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
