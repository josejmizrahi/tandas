'use client'

import { useActionState, useState, useTransition } from 'react'
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import { archiveRule, type ActionResult } from '../actions'

export default function RuleArchiveDialog({
  ruleId, groupId,
}: { ruleId: string; groupId: string }) {
  const [open, setOpen] = useState(false)
  const [, startTransition] = useTransition()
  const [, action] = useActionState<ActionResult | null, FormData>(archiveRule, null)

  function confirm() {
    const fd = new FormData()
    fd.set('rule_id', ruleId)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
    setOpen(false)
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button variant="outline" className="w-full">Archivar regla</Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>¿Archivar esta regla?</AlertDialogTitle>
          <AlertDialogDescription>
            La regla deja de aplicarse a eventos futuros. Las multas pasadas que
            generó no se borran. Puedes proponer reactivarla con una nueva votación.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancelar</AlertDialogCancel>
          <AlertDialogAction onClick={confirm}>Sí, archivar</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
