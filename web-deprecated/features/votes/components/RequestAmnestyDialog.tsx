'use client'

import { useActionState, useState } from 'react'
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import {
  Field, FieldDescription, FieldGroup, FieldLabel,
} from '@/components/ui/field'
import { Loader2, Heart } from 'lucide-react'
import { requestAmnesty, type ActionResult } from '../actions'

export default function RequestAmnestyDialog({ groupId }: { groupId: string }) {
  const [open, setOpen] = useState(false)
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(requestAmnesty, null)

  if (state && 'ok' in state && state.ok && open) setOpen(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Heart className="size-4 mr-1" />
          Proponer amnistía
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader className="space-y-2">
          <DialogTitle>Amnistía general</DialogTitle>
          <DialogDescription>
            Abre una votación del grupo. Si pasa, todas las multas sin pagar
            quedan anuladas. Útil cuando el ambiente está tenso o como gesto colectivo.
          </DialogDescription>
        </DialogHeader>
        <form action={action} className="space-y-4">
          <input type="hidden" name="group_id" value={groupId} />
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="reason">Por qué la propones</FieldLabel>
              <Textarea
                id="reason"
                name="reason"
                rows={4}
                required
                minLength={2}
                maxLength={500}
                placeholder="Ej: Cumpleaños del grupo. Año pesado. Mejor empezar limpios."
              />
            </Field>
            {state && 'error' in state && (
              <FieldDescription className="text-destructive">
                {state.error._form?.[0] ?? state.error.reason?.[0]}
              </FieldDescription>
            )}
          </FieldGroup>
          <DialogFooter className="gap-2">
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>Cancelar</Button>
            <Button type="submit" disabled={pending}>
              {pending && <Loader2 className="size-4 animate-spin mr-2" />}
              {pending ? 'Abriendo…' : 'Abrir votación'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
