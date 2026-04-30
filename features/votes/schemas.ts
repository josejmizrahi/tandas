import { z } from 'zod'
import { VoteChoiceSchema } from '@/lib/schemas/enums'

export const CastBallotSchema = z.object({
  vote_id: z.string().uuid(),
  choice: VoteChoiceSchema,
})
export type CastBallot = z.infer<typeof CastBallotSchema>

export const CloseVoteSchema = z.object({
  vote_id: z.string().uuid(),
})
export type CloseVote = z.infer<typeof CloseVoteSchema>
