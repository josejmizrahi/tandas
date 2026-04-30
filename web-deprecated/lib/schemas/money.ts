import { z } from 'zod'

export const MoneyAmountSchema = z.coerce
  .number()
  .nonnegative()
  .max(99_999_999.99)
  .multipleOf(0.01)

export type MoneyAmount = z.infer<typeof MoneyAmountSchema>

export function formatMxn(value: number): string {
  return new Intl.NumberFormat('es-MX', {
    style: 'currency',
    currency: 'MXN',
    minimumFractionDigits: 2,
  }).format(value)
}
