import { z } from 'zod'

const Uuid = z.string().uuid()

export const GroupIdSchema   = Uuid.brand<'GroupId'>()
export const EventIdSchema   = Uuid.brand<'EventId'>()
export const UserIdSchema    = Uuid.brand<'UserId'>()
export const RuleIdSchema    = Uuid.brand<'RuleId'>()
export const FineIdSchema    = Uuid.brand<'FineId'>()
export const VoteIdSchema    = Uuid.brand<'VoteId'>()
export const PotIdSchema     = Uuid.brand<'PotId'>()
export const ExpenseIdSchema = Uuid.brand<'ExpenseId'>()
export const PaymentIdSchema = Uuid.brand<'PaymentId'>()

export type GroupId   = z.infer<typeof GroupIdSchema>
export type EventId   = z.infer<typeof EventIdSchema>
export type UserId    = z.infer<typeof UserIdSchema>
export type RuleId    = z.infer<typeof RuleIdSchema>
export type FineId    = z.infer<typeof FineIdSchema>
export type VoteId    = z.infer<typeof VoteIdSchema>
export type PotId     = z.infer<typeof PotIdSchema>
export type ExpenseId = z.infer<typeof ExpenseIdSchema>
export type PaymentId = z.infer<typeof PaymentIdSchema>
