import { describe, it, expect } from 'vitest'
import { MoneyAmountSchema, formatMxn } from '../money'

describe('MoneyAmountSchema', () => {
  it('coerces strings to numbers', () => {
    expect(MoneyAmountSchema.parse('250.50')).toBe(250.5)
  })
  it('accepts integers', () => {
    expect(MoneyAmountSchema.parse(100)).toBe(100)
  })
  it('rejects negative', () => {
    expect(() => MoneyAmountSchema.parse(-1)).toThrow()
  })
  it('rejects more than 2 decimals', () => {
    expect(() => MoneyAmountSchema.parse(10.123)).toThrow()
  })
})

describe('formatMxn', () => {
  it('formats with $ and 2 decimals', () => {
    expect(formatMxn(1234.5)).toMatch(/\$1,234\.50/)
  })
  it('formats zero', () => {
    expect(formatMxn(0)).toMatch(/\$0\.00/)
  })
})
