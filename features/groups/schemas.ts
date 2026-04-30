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
