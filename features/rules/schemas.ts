import { z } from 'zod'

const TriggerSchema = z.object({
  type: z.enum([
    'late_arrival', 'no_confirmation', 'same_day_cancel', 'no_show',
    'host_skip_no_notice', 'host_food_late', 'manual',
  ]),
  params: z.record(z.string(), z.unknown()).optional(),
})

const ActionSchema = z.object({
  type: z.literal('fine'),
  params: z.object({ amount: z.coerce.number().nonnegative() }).optional(),
})

export const ProposeRuleSchema = z.object({
  group_id: z.string().uuid(),
  title: z.string().min(2, 'Mínimo 2 caracteres').max(120, 'Máximo 120'),
  description: z.string().max(500, 'Máximo 500').optional(),
  trigger: TriggerSchema,
  action: ActionSchema,
  exceptions: z.array(z.object({ user_id: z.string().uuid() })).default([]),
  committee_only: z.union([z.literal('on'), z.literal('off'), z.boolean()])
    .transform((v) => v === true || v === 'on').optional(),
})
export type ProposeRule = z.infer<typeof ProposeRuleSchema>

export const ArchiveRuleSchema = z.object({
  rule_id: z.string().uuid(),
})
export type ArchiveRule = z.infer<typeof ArchiveRuleSchema>

export const UpdateExceptionsSchema = z.object({
  rule_id: z.string().uuid(),
  user_ids: z.array(z.string().uuid()),
})
export type UpdateExceptions = z.infer<typeof UpdateExceptionsSchema>
