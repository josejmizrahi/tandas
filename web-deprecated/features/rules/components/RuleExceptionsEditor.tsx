'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { updateRuleExceptions, type ActionResult } from '../actions'

type Member = { user_id: string; display_name: string | null }

function initials(name: string | null): string {
  if (!name) return '?'
  return name.split(/\s+/).slice(0, 2).map((p) => p.charAt(0).toUpperCase()).join('')
}

export default function RuleExceptionsEditor({
  ruleId, groupId, members, currentExceptions,
}: {
  ruleId: string
  groupId: string
  members: Member[]
  currentExceptions: string[]
}) {
  const [selected, setSelected] = useState<Set<string>>(new Set(currentExceptions))
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(updateRuleExceptions, null)

  function toggle(uid: string) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(uid)) next.delete(uid)
      else next.add(uid)
      return next
    })
  }

  return (
    <form action={action} className="space-y-4">
      <input type="hidden" name="rule_id" value={ruleId} />
      <input type="hidden" name="gid" value={groupId} />
      {Array.from(selected).map((uid) => (
        <input key={uid} type="hidden" name="user_ids" value={uid} />
      ))}

      <ul className="divide-y rounded-lg border bg-card">
        {members.map((m) => (
          <li key={m.user_id} className="flex items-center gap-3 p-3">
            <Checkbox
              id={`ex-${m.user_id}`}
              checked={selected.has(m.user_id)}
              onCheckedChange={() => toggle(m.user_id)}
            />
            <Avatar className="size-8">
              <AvatarFallback>{initials(m.display_name)}</AvatarFallback>
            </Avatar>
            <label htmlFor={`ex-${m.user_id}`} className="flex-1 font-medium cursor-pointer">
              {m.display_name ?? 'Sin nombre'}
            </label>
          </li>
        ))}
      </ul>

      {state && 'error' in state && (
        <p className="text-destructive text-sm">{state.error._form?.[0]}</p>
      )}

      <Button type="submit" disabled={pending} variant="outline" className="w-full">
        {pending ? 'Guardando…' : 'Guardar excepciones'}
      </Button>
    </form>
  )
}
