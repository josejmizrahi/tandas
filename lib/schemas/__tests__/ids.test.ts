import { describe, it, expect } from 'vitest'
import { GroupIdSchema, EventIdSchema } from '../ids'

describe('GroupIdSchema', () => {
  it('accepts a valid uuid', () => {
    const id = '550e8400-e29b-41d4-a716-446655440000'
    const parsed = GroupIdSchema.parse(id)
    expect(parsed).toBe(id)
  })

  it('rejects an invalid uuid', () => {
    expect(() => GroupIdSchema.parse('not-a-uuid')).toThrow()
  })

  it('GroupId and EventId are not assignable to each other (compile-only)', () => {
    const g = GroupIdSchema.parse('550e8400-e29b-41d4-a716-446655440000')
    const e = EventIdSchema.parse('660e8400-e29b-41d4-a716-446655440000')
    expect(g).not.toBe(e)
  })
})
