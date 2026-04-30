'use client'

import { useActionState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { joinByCode, type ActionResult } from '../actions'

export default function JoinByCode() {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(joinByCode, null)
  return (
    <Card className="w-full max-w-md">
      <CardHeader>
        <CardTitle>Unirme a un grupo</CardTitle>
      </CardHeader>
      <CardContent>
        <form action={action} className="space-y-3">
          <div className="space-y-2">
            <Label htmlFor="code">Código de invitación</Label>
            <Input
              id="code"
              name="code"
              required
              placeholder="abc12345"
              autoComplete="off"
              autoCapitalize="off"
            />
            {state && 'error' in state && (
              <p className="text-destructive text-sm">
                {state.error._form?.[0] ?? state.error.code?.[0]}
              </p>
            )}
          </div>
          <Button type="submit" disabled={pending} className="w-full">
            {pending ? 'Verificando…' : 'Unirme'}
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}
