import { z } from 'zod'

export const RsvpStatusSchema      = z.enum(['pending', 'going', 'maybe', 'declined'])
export const VoteSubjectTypeSchema = z.enum(['rule_proposal', 'rule_repeal', 'fine_appeal', 'host_swap', 'general'])
export const VoteChoiceSchema      = z.enum(['yes', 'no', 'abstain'])
export const VoteStatusSchema      = z.enum(['open', 'passed', 'rejected', 'cancelled'])
export const RuleStatusSchema      = z.enum(['proposed', 'active', 'archived'])
export const EventStatusSchema     = z.enum(['scheduled', 'in_progress', 'completed', 'cancelled'])
export const SplitTypeSchema       = z.enum(['equal', 'exact', 'percentage'])
export const PotStatusSchema       = z.enum(['open', 'closed', 'cancelled'])
export const MemberRoleSchema      = z.enum(['admin', 'member'])

export type RsvpStatus      = z.infer<typeof RsvpStatusSchema>
export type VoteSubjectType = z.infer<typeof VoteSubjectTypeSchema>
export type VoteChoice      = z.infer<typeof VoteChoiceSchema>
export type VoteStatus      = z.infer<typeof VoteStatusSchema>
export type RuleStatus      = z.infer<typeof RuleStatusSchema>
export type EventStatus     = z.infer<typeof EventStatusSchema>
export type SplitType       = z.infer<typeof SplitTypeSchema>
export type PotStatus       = z.infer<typeof PotStatusSchema>
export type MemberRole      = z.infer<typeof MemberRoleSchema>
