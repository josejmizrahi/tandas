// Preset library — match common rule patterns from real friend-group regulations.
// Each preset returns a `trigger` JSON understood by `evaluate_event_rules` (Postgres RPC)
// and an `action`. You can edit these in the UI when proposing/adding a rule.

export type RuleTriggerType =
  | 'late_arrival'
  | 'no_confirmation'
  | 'same_day_cancel'
  | 'no_show'
  | 'host_skip_no_notice'
  | 'host_food_late'
  | 'manual'

export type RuleActionType = 'fine' | 'warn'

export type RuleTrigger = {
  type: RuleTriggerType
  params: Record<string, unknown>
}

export type RuleAction = {
  type: RuleActionType
  params?: Record<string, unknown>
}

export type RulePreset = {
  key: string
  title: string
  description: string
  trigger: RuleTrigger
  action: RuleAction
}

export const RULE_PRESETS: RulePreset[] = [
  {
    key: 'late_arrival_tiered',
    title: 'Llegada tarde (escalonada)',
    description:
      'Si el miembro llega después de la hora de corte se cobra una multa base, y aumenta cada N minutos.',
    trigger: {
      type: 'late_arrival',
      params: {
        start_threshold_time: '21:00',
        base_amount: 200,
        step_minutes: 30,
        step_increment: 50,
      },
    },
    action: { type: 'fine' },
  },
  {
    key: 'no_confirmation_monday',
    title: 'No confirmar a tiempo',
    description: 'Multa si no confirma asistencia antes del deadline del grupo (ej: lunes 23:59).',
    trigger: {
      type: 'no_confirmation',
      params: { deadline_offset_hours: 24, fixed_amount: 200 },
    },
    action: { type: 'fine' },
  },
  {
    key: 'same_day_cancel',
    title: 'Cancelar el mismo día',
    description: 'Multa si cancela su asistencia el mismo día sin razón válida.',
    trigger: { type: 'same_day_cancel', params: { fixed_amount: 200 } },
    action: { type: 'fine' },
  },
  {
    key: 'no_show',
    title: 'No-show (no asistió ni avisó)',
    description: 'Multa si confirmó o no respondió y no se presentó.',
    trigger: { type: 'no_show', params: { fixed_amount: 300 } },
    action: { type: 'fine' },
  },
  {
    key: 'host_skip_no_notice',
    title: 'Anfitrión no avisó que no podía',
    description:
      'Multa si al anfitrión le tocaba y no avisó antes del deadline (ej: domingo 18:00).',
    trigger: {
      type: 'host_skip_no_notice',
      params: { deadline_day: 'sunday', deadline_time: '18:00', fixed_amount: 1000 },
    },
    action: { type: 'fine' },
  },
  {
    key: 'host_food_late',
    title: 'Comida del anfitrión tarde',
    description: 'Multa si la comida no estuvo lista antes de la hora acordada.',
    trigger: { type: 'host_food_late', params: { deadline_time: '20:45', fixed_amount: 200 } },
    action: { type: 'fine' },
  },
  {
    key: 'manual',
    title: 'Manual / personalizada',
    description: 'No se aplica automáticamente. El admin la asigna a quien decida.',
    trigger: { type: 'manual', params: {} },
    action: { type: 'fine' },
  },
]

export const TRIGGER_LABELS: Record<RuleTriggerType, string> = {
  late_arrival: 'Llegada tarde',
  no_confirmation: 'No confirmó',
  same_day_cancel: 'Cancelación del día',
  no_show: 'No-show',
  host_skip_no_notice: 'Anfitrión sin aviso',
  host_food_late: 'Comida tarde',
  manual: 'Manual',
}

export function describeTrigger(trigger: RuleTrigger): string {
  const p = trigger.params || {}
  switch (trigger.type) {
    case 'late_arrival': {
      const t = p.start_threshold_time as string | undefined
      const base = p.base_amount as number | undefined
      const step = p.step_minutes as number | undefined
      const inc = p.step_increment as number | undefined
      return `Después de ${t ?? 'inicio'}: $${base ?? 0}, +$${inc ?? 0} cada ${step ?? 30} min.`
    }
    case 'no_confirmation': {
      const h = p.deadline_offset_hours as number | undefined
      const f = p.fixed_amount as number | undefined
      return `Confirmar mín. ${h ?? 24} h antes — multa $${f ?? 0}.`
    }
    case 'same_day_cancel':
      return `Cancelar mismo día — multa $${(p.fixed_amount as number) ?? 0}.`
    case 'no_show':
      return `No-show — multa $${(p.fixed_amount as number) ?? 0}.`
    case 'host_skip_no_notice':
      return `Anfitrión sin aviso (${p.deadline_day} ${p.deadline_time}) — multa $${(p.fixed_amount as number) ?? 0}.`
    case 'host_food_late':
      return `Comida después de ${p.deadline_time} — multa $${(p.fixed_amount as number) ?? 0}.`
    case 'manual':
      return 'Asignación manual.'
  }
}
