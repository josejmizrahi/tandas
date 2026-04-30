import { describe, it, expect } from 'vitest'
import { formatEventDate, isPastEvent, isToday, isUpcoming } from './dates'

describe('formatEventDate', () => {
  it('formats with day name + day + month + time in es-MX', () => {
    const out = formatEventDate('2026-05-12T20:30:00.000Z', 'America/Mexico_City')
    expect(out).toMatch(/martes/i)
    expect(out).toMatch(/12/)
  })
})

describe('isPastEvent', () => {
  it('returns true for past starts_at', () => {
    expect(isPastEvent('2020-01-01T00:00:00.000Z')).toBe(true)
  })
  it('returns false for future starts_at', () => {
    const future = new Date(Date.now() + 86_400_000).toISOString()
    expect(isPastEvent(future)).toBe(false)
  })
})

describe('isToday', () => {
  it('returns true for today', () => {
    expect(isToday(new Date().toISOString(), 'America/Mexico_City')).toBe(true)
  })
})

describe('isUpcoming', () => {
  it('returns true within next 14 days', () => {
    const soon = new Date(Date.now() + 7 * 86_400_000).toISOString()
    expect(isUpcoming(soon)).toBe(true)
  })
  it('returns false for events more than 14 days out', () => {
    const far = new Date(Date.now() + 30 * 86_400_000).toISOString()
    expect(isUpcoming(far)).toBe(false)
  })
})
