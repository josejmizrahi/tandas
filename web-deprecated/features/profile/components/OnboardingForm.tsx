'use client'

import { useActionState } from 'react'
import { Loader2, ArrowRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Field, FieldDescription, FieldGroup, FieldLabel,
} from '@/components/ui/field'
import { updateProfile, type ActionResult } from '../actions'

export default function OnboardingForm({ defaultName }: { defaultName?: string }) {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(updateProfile, null)

  return (
    <form action={action} className="w-full">
      <FieldGroup>
        <Field>
          <FieldLabel htmlFor="display_name">Tu nombre</FieldLabel>
          <Input
            id="display_name"
            name="display_name"
            type="text"
            placeholder="Pepe Pérez"
            defaultValue={defaultName}
            autoComplete="name"
            required
            maxLength={50}
            autoFocus
          />
          <FieldDescription>
            Usamos esto en la lista de miembros y al asignarte multas o turnos.
          </FieldDescription>
          {state && 'error' in state && (
            <FieldDescription className="text-destructive">
              {state.error._form?.[0] ?? state.error.display_name?.[0]}
            </FieldDescription>
          )}
        </Field>
        <Field>
          <Button type="submit" disabled={pending} size="lg">
            {pending && <Loader2 className="size-4 animate-spin mr-2" />}
            {pending ? 'Guardando…' : 'Continuar'}
            {!pending && <ArrowRight className="size-4 ml-2" />}
          </Button>
        </Field>
      </FieldGroup>
    </form>
  )
}
