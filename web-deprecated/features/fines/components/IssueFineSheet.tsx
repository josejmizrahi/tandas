'use client'

import { useActionState, useState } from 'react'
import {
  Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle, SheetTrigger,
} from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import {
  Field, FieldDescription, FieldGroup, FieldLabel,
} from '@/components/ui/field'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { Loader2, Plus } from 'lucide-react'
import { issueManualFine, type ActionResult } from '../actions'

type Member = { user_id: string; display_name: string | null }

export default function IssueFineSheet({
  groupId, members,
}: { groupId: string; members: Member[] }) {
  const [open, setOpen] = useState(false)
  const [userId, setUserId] = useState<string>('')
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(issueManualFine, null)

  if (state && 'ok' in state && state.ok && open) setOpen(false)

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger asChild>
        <Button variant="outline" size="sm">
          <Plus className="size-4 mr-1" />
          Nueva multa
        </Button>
      </SheetTrigger>
      <SheetContent side="bottom" className="h-[80dvh]">
        <SheetHeader className="space-y-2">
          <SheetTitle>Nueva multa manual</SheetTitle>
          <SheetDescription>
            Asigna una multa a un miembro fuera del rule engine. Útil para casos que las reglas no cubren.
          </SheetDescription>
        </SheetHeader>

        <form action={action} className="space-y-4 px-4 pt-4">
          <input type="hidden" name="group_id" value={groupId} />
          <input type="hidden" name="user_id" value={userId} />

          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="member">A quién</FieldLabel>
              <Select value={userId} onValueChange={setUserId}>
                <SelectTrigger id="member">
                  <SelectValue placeholder="Elige miembro" />
                </SelectTrigger>
                <SelectContent>
                  {members.map((m) => (
                    <SelectItem key={m.user_id} value={m.user_id}>
                      {m.display_name ?? 'Sin nombre'}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>

            <Field>
              <FieldLabel htmlFor="amount">Monto (MXN)</FieldLabel>
              <Input id="amount" name="amount" type="number" min={0} step={50} required defaultValue={200} />
            </Field>

            <Field>
              <FieldLabel htmlFor="reason">Motivo</FieldLabel>
              <Textarea
                id="reason"
                name="reason"
                rows={3}
                placeholder="Ej: Rompió la copa de la abuela. Llegó en pijama."
                required
                minLength={2}
                maxLength={200}
              />
              <FieldDescription>El grupo lo va a leer.</FieldDescription>
            </Field>

            {state && 'error' in state && (
              <FieldDescription className="text-destructive">
                {state.error._form?.[0]}
              </FieldDescription>
            )}
          </FieldGroup>

          <SheetFooter className="px-0">
            <Button type="submit" disabled={pending || !userId} size="lg" className="w-full">
              {pending && <Loader2 className="size-4 animate-spin mr-2" />}
              {pending ? 'Asignando…' : 'Asignar multa'}
            </Button>
          </SheetFooter>
        </form>
      </SheetContent>
    </Sheet>
  )
}
