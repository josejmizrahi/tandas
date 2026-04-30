export type RulePreset = {
  code: string
  title: string
  description: string
  trigger: { type: string; params?: Record<string, unknown> }
  action: { type: 'fine'; params?: { amount?: number } }
}

export const RULE_PRESETS: RulePreset[] = [
  {
    code: 'late_arrival',
    title: 'Llegada tarde',
    description: 'Multa escalonada por llegar tarde después de la hora de inicio.',
    trigger: {
      type: 'late_arrival',
      params: { start_threshold_time: '20:30', step_minutes: 30, base_amount: 200, step_increment: 50, max_amount: 500 },
    },
    action: { type: 'fine', params: { amount: 200 } },
  },
  {
    code: 'no_confirmation',
    title: 'No confirmar a tiempo',
    description: 'Multa fija si no respondes RSVP antes del deadline.',
    trigger: { type: 'no_confirmation', params: { deadline_offset_hours: 24, fixed_amount: 200 } },
    action: { type: 'fine', params: { amount: 200 } },
  },
  {
    code: 'same_day_cancel',
    title: 'Cancelar el mismo día',
    description: 'Multa fija si cancelas tu asistencia el mismo día del evento.',
    trigger: { type: 'same_day_cancel', params: { fixed_amount: 200 } },
    action: { type: 'fine', params: { amount: 200 } },
  },
  {
    code: 'no_show',
    title: 'No-show',
    description: 'Multa fija si confirmaste y no llegaste sin avisar.',
    trigger: { type: 'no_show', params: { fixed_amount: 300 } },
    action: { type: 'fine', params: { amount: 300 } },
  },
  {
    code: 'host_skip_no_notice',
    title: 'Anfitrión sin avisar',
    description: 'Multa al anfitrión que no avisa con tiempo que no puede hostear.',
    trigger: { type: 'host_skip_no_notice', params: { notice_hours: 48, fixed_amount: 300 } },
    action: { type: 'fine', params: { amount: 300 } },
  },
  {
    code: 'host_food_late',
    title: 'Comida tarde del anfitrión',
    description: 'Multa al anfitrión si la comida se sirve después de la hora prometida.',
    trigger: { type: 'host_food_late', params: { fixed_amount: 100 } },
    action: { type: 'fine', params: { amount: 100 } },
  },
  {
    code: 'manual',
    title: 'Manual (a discreción)',
    description: 'Regla sin trigger automático. Las multas se asignan a mano.',
    trigger: { type: 'manual' },
    action: { type: 'fine', params: { amount: 100 } },
  },
]

export function presetByCode(code: string): RulePreset | undefined {
  return RULE_PRESETS.find((p) => p.code === code)
}
