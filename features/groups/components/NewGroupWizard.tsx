'use client'

import { useActionState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { createGroup, type ActionResult } from '../actions'

const DAYS = [
  { v: 0, l: 'Domingo' }, { v: 1, l: 'Lunes' }, { v: 2, l: 'Martes' },
  { v: 3, l: 'Miércoles' }, { v: 4, l: 'Jueves' }, { v: 5, l: 'Viernes' }, { v: 6, l: 'Sábado' },
]

export default function NewGroupWizard() {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(createGroup, null)

  return (
    <Card className="w-full max-w-md">
      <CardHeader>
        <CardTitle>Nuevo grupo</CardTitle>
      </CardHeader>
      <CardContent>
        <form action={action} className="space-y-4">
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
              <select
                id="default_day_of_week"
                name="default_day_of_week"
                className="w-full h-10 rounded-md border border-input bg-background px-3 text-sm"
              >
                <option value="">—</option>
                {DAYS.map((d) => <option key={d.v} value={d.v}>{d.l}</option>)}
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="default_start_time">Hora default</Label>
              <Input id="default_start_time" name="default_start_time" type="time" defaultValue="20:30" />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-2">
              <Label htmlFor="voting_threshold">Umbral voto (0–1)</Label>
              <Input id="voting_threshold" name="voting_threshold" type="number" step="0.05" min="0.01" max="1" defaultValue="0.5" />
            </div>
            <div className="space-y-2">
              <Label htmlFor="voting_quorum">Quórum (0–1)</Label>
              <Input id="voting_quorum" name="voting_quorum" type="number" step="0.05" min="0.01" max="1" defaultValue="0.5" />
            </div>
          </div>

          <div className="flex items-center gap-2">
            <input id="fund_enabled" name="fund_enabled" type="checkbox" defaultChecked className="size-4 rounded" />
            <Label htmlFor="fund_enabled" className="text-sm">Activar fondo común</Label>
          </div>

          {state && 'error' in state && (
            <p className="text-destructive text-sm">{state.error._form?.[0]}</p>
          )}

          <Button type="submit" disabled={pending} className="w-full">
            {pending ? 'Creando…' : 'Crear grupo'}
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}
