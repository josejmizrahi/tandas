'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Checkbox } from '@/components/ui/checkbox'
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
        <CardDescription>Configura los parámetros del grupo. Puedes cambiarlos después.</CardDescription>
      </CardHeader>
      <CardContent>
        <form action={action} className="space-y-5">
          <div className="space-y-2">
            <Label htmlFor="name">Nombre del grupo</Label>
            <Input id="name" name="name" placeholder="La Tanda de los Martes" required minLength={2} maxLength={60} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="event_label">¿Cómo le dicen al evento?</Label>
            <Input id="event_label" name="event_label" defaultValue="Tanda" placeholder="Tanda / Cena / Reunión" />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-2">
              <Label htmlFor="default_day_of_week">Día default</Label>
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
            </div>
            <div className="space-y-2">
              <Label htmlFor="default_start_time">Hora default</Label>
              <Input id="default_start_time" name="default_start_time" type="time" defaultValue="20:30" />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-2">
              <Label htmlFor="voting_threshold">Umbral voto</Label>
              <Input id="voting_threshold" name="voting_threshold" type="number" step="0.05" min="0.01" max="1" defaultValue="0.5" />
              <p className="text-xs text-muted-foreground">0.01 a 1</p>
            </div>
            <div className="space-y-2">
              <Label htmlFor="voting_quorum">Quórum</Label>
              <Input id="voting_quorum" name="voting_quorum" type="number" step="0.05" min="0.01" max="1" defaultValue="0.5" />
              <p className="text-xs text-muted-foreground">0.01 a 1</p>
            </div>
          </div>

          <div className="flex items-start gap-3">
            <Checkbox
              id="fund_enabled"
              checked={fundEnabled}
              onCheckedChange={(v) => setFundEnabled(v === true)}
            />
            <input type="hidden" name="fund_enabled" value={fundEnabled ? 'on' : 'off'} />
            <div className="space-y-1 leading-none">
              <Label htmlFor="fund_enabled" className="text-sm font-medium">
                Activar fondo común
              </Label>
              <p className="text-xs text-muted-foreground">
                Las multas pagadas se acumulan en una caja del grupo.
              </p>
            </div>
          </div>

          {state && 'error' in state && (
            <p className="text-destructive text-sm">{state.error._form?.[0]}</p>
          )}

          <Button type="submit" disabled={pending} className="w-full" size="lg">
            {pending ? 'Creando…' : 'Crear grupo'}
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}
