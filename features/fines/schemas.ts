import { z } from 'zod'

export const PayFineSchema = z.object({
  fine_id: z.string().uuid(),
})
export type PayFine = z.infer<typeof PayFineSchema>

export const IssueManualFineSchema = z.object({
  group_id: z.string().uuid(),
  user_id: z.string().uuid(),
  amount: z.coerce.number().nonnegative('Monto inválido').max(99_999_999.99),
  reason: z.string().min(2, 'Mínimo 2 caracteres').max(200, 'Máximo 200'),
  rule_id: z.string().uuid().optional().nullable(),
  event_id: z.string().uuid().optional().nullable(),
})
export type IssueManualFine = z.infer<typeof IssueManualFineSchema>

export const OpenFineAppealSchema = z.object({
  fine_id: z.string().uuid(),
  reason: z.string().min(2, 'Cuéntale al grupo por qué la apelas').max(500, 'Máximo 500'),
})
export type OpenFineAppeal = z.infer<typeof OpenFineAppealSchema>
