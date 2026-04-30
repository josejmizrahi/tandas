import { z } from 'zod'

export const JoinByCodeSchema = z.object({
  code: z.string().min(4, 'Código inválido').max(16, 'Código inválido'),
})
export type JoinByCode = z.infer<typeof JoinByCodeSchema>
