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
import { Loader2, Scale } from 'lucide-react'
import { openFineAppeal, type ActionResult } from '../actions'

export default function AppealFineDialog({ fineId }: { fineId: string }) {
  const [open, setOpen] = useState(false)
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(openFineAppeal, null)

  if (state && 'ok' in state && state.ok && open) setOpen(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" className="w-full">
          <Scale className="size-4 mr-2" />
          Apelar
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader className="space-y-2">
          <DialogTitle>Apelar esta multa</DialogTitle>
          <DialogDescription>
            Se abre una votación del grupo. Si pasa el quórum + umbral, la multa queda anulada.
          </DialogDescription>
        </DialogHeader>
        <form action={action} className="space-y-4">
          <input type="hidden" name="fine_id" value={fineId} />
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="reason">Por qué la apelas</FieldLabel>
              <Textarea
                id="reason"
                name="reason"
                rows={4}
                required
                minLength={2}
                maxLength={500}
                placeholder="Cuéntale al grupo tu lado."
              />
            </Field>
            {state && 'error' in state && (
              <FieldDescription className="text-destructive">
                {state.error._form?.[0]}
              </FieldDescription>
            )}
          </FieldGroup>
          <DialogFooter className="gap-2">
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>Cancelar</Button>
            <Button type="submit" disabled={pending}>
              {pending && <Loader2 className="size-4 animate-spin mr-2" />}
              {pending ? 'Abriendo…' : 'Abrir apelación'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
