'use client'

import { useActionState, useTransition, useState } from 'react'
import { Button } from '@/components/ui/button'
import { CheckCircle2 } from 'lucide-react'
import { checkInAttendee, type ActionResult } from '../actions'

export default function CheckInButton({
  eventId, userId, groupId, alreadyCheckedIn,
}: { eventId: string; userId: string; groupId: string; alreadyCheckedIn: boolean }) {
  const [didIt, setDidIt] = useState(alreadyCheckedIn)
  const [, startTransition] = useTransition()
  const [, action] = useActionState<ActionResult | null, FormData>(checkInAttendee, null)

  function handleClick() {
    setDidIt(true)
    const fd = new FormData()
    fd.set('event_id', eventId)
    fd.set('user_id', userId)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
  }

  return (
    <Button
      onClick={handleClick}
      disabled={didIt}
      size="lg"
      className="w-full"
      variant={didIt ? 'outline' : 'default'}
    >
      <CheckCircle2 className="size-5 mr-2" />
      {didIt ? 'Ya marcaste tu llegada' : 'Marcar mi llegada'}
    </Button>
  )
}
