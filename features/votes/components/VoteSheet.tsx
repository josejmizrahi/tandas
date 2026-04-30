'use client'

import { useActionState, useTransition, useState } from 'react'
import { Button } from '@/components/ui/button'
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group'
import { Label } from '@/components/ui/label'
import { Card, CardContent } from '@/components/ui/card'
import { castBallot, closeVote, type ActionResult } from '../actions'
import VoteTallyBar from './VoteTallyBar'
import type { VoteTally } from '../queries'

type Choice = 'yes' | 'no' | 'abstain'

export default function VoteSheet({
  voteId, groupId, ruleId, currentChoice, tally, isAdmin, closesAt,
}: {
  voteId: string
  groupId: string
  ruleId: string | null
  currentChoice: Choice | null
  tally: VoteTally
  isAdmin: boolean
  closesAt: string
}) {
  const [optimistic, setOptimistic] = useState<Choice | null>(currentChoice)
  const [, startTransition] = useTransition()
  const [castState, castAction] = useActionState<ActionResult | null, FormData>(castBallot, null)
  const [closeState, closeAction] = useActionState<ActionResult | null, FormData>(closeVote, null)
  const canCloseManually = isAdmin || new Date(closesAt) <= new Date()

  function handleChoice(value: string) {
    const choice = value as Choice
    setOptimistic(choice)
    const fd = new FormData()
    fd.set('vote_id', voteId)
    fd.set('choice', choice)
    fd.set('gid', groupId)
    if (ruleId) fd.set('rule_id', ruleId)
    startTransition(() => castAction(fd))
  }

  function handleClose() {
    const fd = new FormData()
    fd.set('vote_id', voteId)
    fd.set('gid', groupId)
    if (ruleId) fd.set('rule_id', ruleId)
    startTransition(() => closeAction(fd))
  }

  return (
    <Card>
      <CardContent className="p-4 space-y-4">
        <VoteTallyBar tally={tally} />

        <div className="space-y-2">
          <p className="text-sm font-medium">Tu voto</p>
          <RadioGroup
            value={optimistic ?? ''}
            onValueChange={handleChoice}
            className="grid grid-cols-3 gap-2"
          >
            {(['yes', 'no', 'abstain'] as const).map((c) => (
              <Label
                key={c}
                htmlFor={`vote-${c}`}
                className="flex flex-col items-center justify-center gap-1 rounded-lg border p-3 cursor-pointer has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5"
              >
                <RadioGroupItem value={c} id={`vote-${c}`} className="sr-only" />
                <span className="font-medium">
                  {c === 'yes' && 'Sí'}
                  {c === 'no' && 'No'}
                  {c === 'abstain' && 'Abstención'}
                </span>
              </Label>
            ))}
          </RadioGroup>
          {castState && 'error' in castState && (
            <p className="text-destructive text-xs">{castState.error._form?.[0]}</p>
          )}
        </div>

        <p className="text-xs text-muted-foreground text-center">
          Cierra: {new Intl.DateTimeFormat('es-MX', {
            weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit',
          }).format(new Date(closesAt))}
        </p>

        {canCloseManually && (
          <Button variant="outline" className="w-full" onClick={handleClose}>
            Cerrar votación ahora
          </Button>
        )}
        {closeState && 'error' in closeState && (
          <p className="text-destructive text-xs">{closeState.error._form?.[0]}</p>
        )}
      </CardContent>
    </Card>
  )
}
