'use client'

import { useActionState, useState } from 'react'
import {
  Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle, SheetTrigger,
} from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Plus } from 'lucide-react'
import { createEvent, type ActionResult } from '../actions'

export default function NewEventSheet({ groupId }: { groupId: string }) {
  const [open, setOpen] = useState(false)
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(createEvent, null)

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger asChild>
        <Button className="w-full" size="lg">
          <Plus className="size-4 mr-2" />
          Nuevo evento
        </Button>
      </SheetTrigger>
      <SheetContent side="bottom" className="h-[88dvh]">
        <SheetHeader className="space-y-2">
          <SheetTitle>Nuevo evento</SheetTitle>
          <SheetDescription>
            Crea un evento puntual. Si tu grupo tiene rotación, el siguiente se crea solo al cerrar éste.
          </SheetDescription>
        </SheetHeader>
        <form action={action} className="space-y-4 px-4 pt-4 overflow-y-auto">
          <input type="hidden" name="group_id" value={groupId} />

          <div className="space-y-2">
            <Label htmlFor="title">Título (opcional)</Label>
            <Input id="title" name="title" placeholder="Cena en casa de Eduardo" maxLength={120} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="starts_at">Fecha y hora</Label>
            <Input id="starts_at" name="starts_at" type="datetime-local" required />
          </div>

          <div className="space-y-2">
            <Label htmlFor="location">Lugar (opcional)</Label>
            <Input id="location" name="location" placeholder="Casa de Eduardo, Polanco" maxLength={200} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="rsvp_deadline">Deadline para confirmar (opcional)</Label>
            <Input id="rsvp_deadline" name="rsvp_deadline" type="datetime-local" />
            <p className="text-xs text-muted-foreground">
              Si lo dejas vacío, usamos 24h antes del evento.
            </p>
          </div>

          {state && 'error' in state && (
            <p className="text-destructive text-sm">{state.error._form?.[0]}</p>
          )}

          <SheetFooter className="px-0">
            <Button type="submit" disabled={pending} className="w-full" size="lg">
              {pending ? 'Creando…' : 'Crear evento'}
            </Button>
          </SheetFooter>
        </form>
      </SheetContent>
    </Sheet>
  )
}
