'use client'

import { useActionState, useTransition } from 'react'
import { CheckCircle2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { payFine, type ActionResult } from '../actions'

export default function PayFineButton({
  fineId, groupId, fundEnabled,
}: { fineId: string; groupId: string; fundEnabled: boolean }) {
  const [, startTransition] = useTransition()
  const [state, action] = useActionState<ActionResult | null, FormData>(payFine, null)

  function handlePay() {
    const fd = new FormData()
    fd.set('fine_id', fineId)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
  }

  return (
    <div className="space-y-2">
      <Button onClick={handlePay} size="lg" className="w-full">
        <CheckCircle2 className="size-4 mr-2" />
        Marcar como pagada
      </Button>
      <p className="text-xs text-muted-foreground text-center">
        {fundEnabled
          ? 'El monto pagado se acumula en el fondo común del grupo.'
          : 'Tú coordinas el pago con el grupo aparte.'}
      </p>
      {state && 'error' in state && (
        <p className="text-destructive text-xs text-center">{state.error._form?.[0]}</p>
      )}
    </div>
  )
}
