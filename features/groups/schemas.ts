import { z } from 'zod'

export const CreateGroupSchema = z.object({
  name: z.string().min(2, 'Mínimo 2 caracteres').max(60, 'Máximo 60'),
  event_label: z.string().min(2).max(30).default('Tanda'),
  currency: z.enum(['MXN', 'USD', 'EUR']).default('MXN'),
  timezone: z.string().default('America/Mexico_City'),
  default_day_of_week: z.coerce.number().int().min(0).max(6).optional(),
  default_start_time: z.string().regex(/^\d{2}:\d{2}$/).optional(),
  voting_threshold: z.coerce.number().min(0.01).max(1).default(0.5),
  voting_quorum: z.coerce.number().min(0.01).max(1).default(0.5),
  fund_enabled: z
    .union([z.literal('on'), z.literal('off'), z.boolean()])
    .transform((v) => v === true || v === 'on'),
})
export type CreateGroup = z.infer<typeof CreateGroupSchema>

const checkboxToBool = z
  .union([z.literal('on'), z.literal('off'), z.boolean()])
  .transform((v) => v === true || v === 'on')

export const UpdateGroupSettingsSchema = z.object({
  group_id: z.string().uuid(),
  name: z.string().min(2).max(60),
  event_label: z.string().min(2).max(30),
  default_day_of_week: z.coerce.number().int().min(0).max(6).optional(),
  default_start_time: z.string().regex(/^\d{2}:\d{2}$/).optional(),
  default_location: z.string().max(200).optional(),
  voting_threshold: z.coerce.number().min(0.01).max(1),
  voting_quorum: z.coerce.number().min(0.01).max(1),
  vote_duration_hours: z.coerce.number().int().min(1).max(720),
  no_show_grace_minutes: z.coerce.number().int().min(5).max(720),
  grace_period_events: z.coerce.number().int().min(0).max(50),
  monthly_fine_cap_mxn: z
    .union([z.literal(''), z.coerce.number().nonnegative()])
    .transform((v) => (v === '' ? null : v))
    .nullable()
    .optional(),
  fund_enabled: checkboxToBool,
  committee_required_for_appeals: checkboxToBool,
  block_unpaid_attendance: checkboxToBool,
  rotation_enabled: checkboxToBool,
})
export type UpdateGroupSettings = z.infer<typeof UpdateGroupSettingsSchema>
