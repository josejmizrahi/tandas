'use client'

import { useActionState, useState, useTransition } from 'react'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { setRsvp, type ActionResult } from '../actions'

type Status = 'pending' | 'going' | 'maybe' | 'declined'

const OPTIONS: { value: Status; label: string }[] = [
  { value: 'going', label: 'Voy' },
  { value: 'maybe', label: 'Tal vez' },
  { value: 'declined', label: 'No voy' },
]

export default function RsvpToggle({
  eventId, groupId, currentStatus,
}: { eventId: string; groupId: string; currentStatus: Status }) {
  const [optimistic, setOptimistic] = useState<Status>(currentStatus)
  const [, startTransition] = useTransition()
  const [, action] = useActionState<ActionResult | null, FormData>(setRsvp, null)

  function handleChange(value: string) {
    if (!value) return
    const next = value as Status
    setOptimistic(next)
    const fd = new FormData()
    fd.set('event_id', eventId)
    fd.set('status', next)
    fd.set('gid', groupId)
    startTransition(() => action(fd))
  }

  return (
    <ToggleGroup
      type="single"
      value={optimistic === 'pending' ? '' : optimistic}
      onValueChange={handleChange}
      variant="outline"
      className="w-full"
    >
      {OPTIONS.map((o) => (
        <ToggleGroupItem key={o.value} value={o.value} className="flex-1">
          {o.label}
        </ToggleGroupItem>
      ))}
    </ToggleGroup>
  )
}
