'use client'

import { useActionState, useState, useTransition } from 'react'
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import { closeEvent, type ActionResult } from '../actions'

export default function CloseEventDialog({
  eventId, groupId,
}: { eventId: string; groupId: string }) {
  const [open, setOpen] = useState(false)
  const [, startTransition] = useTransition()
  const [, action] = useActionState<ActionResult | null, FormData>(closeEvent, null)

  function confirmClose() {
    const fd = new FormData()
    fd.set('event_id', eventId)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
    setOpen(false)
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button variant="outline" className="w-full" size="lg">Cerrar evento</Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>¿Cerrar este evento?</AlertDialogTitle>
          <AlertDialogDescription>
            Marca el evento como completado. Si tu grupo tiene rotación activada,
            se crea automáticamente el siguiente. Las multas automáticas llegan en Phase 4.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancelar</AlertDialogCancel>
          <AlertDialogAction onClick={confirmClose}>Sí, cerrar</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
