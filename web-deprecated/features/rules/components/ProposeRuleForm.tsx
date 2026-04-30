'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group'
import { proposeRule, type ActionResult } from '../actions'
import { RULE_PRESETS, type RulePreset } from '../presets'

export default function ProposeRuleForm({ groupId }: { groupId: string }) {
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(proposeRule, null)
  const [preset, setPreset] = useState<RulePreset>(RULE_PRESETS[0])
  const [amount, setAmount] = useState<number>(preset.action.params?.amount ?? 200)

  function handlePresetChange(code: string) {
    const next = RULE_PRESETS.find((p) => p.code === code)
    if (next) {
      setPreset(next)
      setAmount(next.action.params?.amount ?? 0)
    }
  }

  // Build the trigger and action JSON with the current amount baked in
  const triggerJson = JSON.stringify({
    ...preset.trigger,
    params: {
      ...(preset.trigger.params ?? {}),
      ...(preset.code === 'late_arrival' ? { base_amount: amount } : { fixed_amount: amount }),
    },
  })
  const actionJson = JSON.stringify({
    ...preset.action,
    params: { amount },
  })

  return (
    <form action={action} className="space-y-5">
      <input type="hidden" name="group_id" value={groupId} />
      <input type="hidden" name="trigger" value={triggerJson} />
      <input type="hidden" name="action" value={actionJson} />

      <div className="space-y-2">
        <Label>Tipo de regla</Label>
        <RadioGroup value={preset.code} onValueChange={handlePresetChange} className="space-y-2">
          {RULE_PRESETS.map((p) => (
            <div key={p.code} className="flex items-start gap-3 rounded-lg border p-3">
              <RadioGroupItem value={p.code} id={`preset-${p.code}`} />
              <div className="space-y-1 leading-none flex-1">
                <Label htmlFor={`preset-${p.code}`} className="font-medium cursor-pointer">
                  {p.title}
                </Label>
                <p className="text-xs text-muted-foreground">{p.description}</p>
              </div>
            </div>
          ))}
        </RadioGroup>
      </div>

      <div className="space-y-2">
        <Label htmlFor="title">Título de la regla</Label>
        <Input
          id="title"
          name="title"
          required
          defaultValue={preset.title}
          minLength={2}
          maxLength={120}
          key={preset.code}
        />
      </div>

      <div className="space-y-2">
        <Label htmlFor="description">Descripción (opcional)</Label>
        <Textarea
          id="description"
          name="description"
          rows={3}
          defaultValue={preset.description}
          maxLength={500}
          key={`desc-${preset.code}`}
        />
      </div>

      <div className="space-y-2">
        <Label htmlFor="amount">Monto de la multa (MXN)</Label>
        <Input
          id="amount"
          type="number"
          min={0}
          step={50}
          value={amount}
          onChange={(e) => setAmount(Number(e.target.value) || 0)}
        />
        {preset.code === 'late_arrival' && (
          <p className="text-xs text-muted-foreground">
            Para reglas escalonadas, este es el monto base. El motor suma {String(preset.trigger.params?.step_increment ?? 50)} MXN por cada {String(preset.trigger.params?.step_minutes ?? 30)} min de retraso.
          </p>
        )}
      </div>

      <div className="flex items-start gap-3 rounded-lg border p-3">
        <input
          id="committee_only"
          name="committee_only"
          type="checkbox"
          className="mt-1 size-4"
        />
        <div className="space-y-1 leading-none">
          <Label htmlFor="committee_only" className="text-sm font-medium">
            Solo comité puede votar
          </Label>
          <p className="text-xs text-muted-foreground">
            Si está marcado, solo los miembros del comité disciplinario votan esta regla.
          </p>
        </div>
      </div>

      {state && 'error' in state && (
        <p className="text-destructive text-sm">{state.error._form?.[0]}</p>
      )}

      <Button type="submit" disabled={pending} size="lg" className="w-full">
        {pending ? 'Proponiendo…' : 'Proponer y abrir votación'}
      </Button>
    </form>
  )
}
