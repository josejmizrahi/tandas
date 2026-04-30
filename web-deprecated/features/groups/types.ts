/**
 * Group typology presets — drives sensible defaults at creation time.
 * Each preset describes the group's nature + recommended config.
 */

export type GroupTypeCode =
  | 'recurring_dinner'
  | 'tanda_savings'
  | 'sports_team'
  | 'study_group'
  | 'band'
  | 'poker'
  | 'family'
  | 'travel'
  | 'other'

export type GroupTypePreset = {
  code: GroupTypeCode
  label: string
  description: string
  icon: string // lucide icon name (string for portability)
  defaults: {
    event_label: string
    rotation_enabled: boolean
    fund_enabled: boolean
    grace_period_events: number
  }
}

export const GROUP_TYPES: GroupTypePreset[] = [
  {
    code: 'recurring_dinner',
    label: 'Cena recurrente',
    description: 'Cena semanal o quincenal con anfitrión rotativo.',
    icon: 'Utensils',
    defaults: { event_label: 'Cena', rotation_enabled: true, fund_enabled: true, grace_period_events: 3 },
  },
  {
    code: 'tanda_savings',
    label: 'Tanda de ahorro',
    description: 'Pozo rotativo: cada miembro aporta y le toca recibir por turno.',
    icon: 'PiggyBank',
    defaults: { event_label: 'Tanda', rotation_enabled: true, fund_enabled: true, grace_period_events: 0 },
  },
  {
    code: 'poker',
    label: 'Grupo de poker',
    description: 'Noche de juego con buy-ins y pots.',
    icon: 'Spade',
    defaults: { event_label: 'Partida', rotation_enabled: true, fund_enabled: false, grace_period_events: 2 },
  },
  {
    code: 'sports_team',
    label: 'Equipo deportivo',
    description: 'Partidos recurrentes; sin anfitrión pero con asistencia.',
    icon: 'Trophy',
    defaults: { event_label: 'Partido', rotation_enabled: false, fund_enabled: true, grace_period_events: 5 },
  },
  {
    code: 'study_group',
    label: 'Grupo de estudio',
    description: 'Chevruta, club de lectura, círculo de discusión.',
    icon: 'BookOpen',
    defaults: { event_label: 'Sesión', rotation_enabled: true, fund_enabled: false, grace_period_events: 3 },
  },
  {
    code: 'band',
    label: 'Banda / proyecto creativo',
    description: 'Ensayos y gigs; equipo y regalías compartidos.',
    icon: 'Music',
    defaults: { event_label: 'Ensayo', rotation_enabled: false, fund_enabled: true, grace_period_events: 5 },
  },
  {
    code: 'family',
    label: 'Reunión familiar',
    description: 'Comidas familiares, cumpleaños, holidays.',
    icon: 'Heart',
    defaults: { event_label: 'Reunión', rotation_enabled: true, fund_enabled: false, grace_period_events: 10 },
  },
  {
    code: 'travel',
    label: 'Grupo de viaje',
    description: 'Viajes recurrentes con caja compartida.',
    icon: 'Plane',
    defaults: { event_label: 'Viaje', rotation_enabled: false, fund_enabled: true, grace_period_events: 0 },
  },
  {
    code: 'other',
    label: 'Otro',
    description: 'Configura todo a tu manera.',
    icon: 'MoreHorizontal',
    defaults: { event_label: 'Evento', rotation_enabled: true, fund_enabled: false, grace_period_events: 3 },
  },
]

export function getGroupTypePreset(code: string): GroupTypePreset {
  return GROUP_TYPES.find((t) => t.code === code) ?? GROUP_TYPES[0]
}
