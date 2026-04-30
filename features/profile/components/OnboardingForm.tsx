'use client'

import { useActionState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { updateProfile, type ActionResult } from '../actions'

export default function OnboardingForm({ defaultName }: { defaultName?: string }) {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(updateProfile, null)

  return (
    <form action={action} className="space-y-4 w-full max-w-sm">
      <div className="space-y-2">
        <Label htmlFor="display_name">Cómo te llamas</Label>
        <Input
          id="display_name"
          name="display_name"
          type="text"
          placeholder="Pepe Pérez"
          defaultValue={defaultName}
          autoComplete="name"
          required
          maxLength={50}
        />
        {state && 'error' in state && (
          <p className="text-destructive text-sm">
            {state.error._form?.[0] ?? state.error.display_name?.[0]}
          </p>
        )}
      </div>
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Guardando…' : 'Listo'}
      </Button>
    </form>
  )
}
