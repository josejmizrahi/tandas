import { z } from 'zod'
import { RsvpStatusSchema } from '@/lib/schemas/enums'

export const CreateEventSchema = z.object({
  group_id: z.string().uuid(),
  starts_at: z.string().datetime(),
  location: z.string().max(200).optional(),
  title: z.string().max(120).optional(),
  rsvp_deadline: z.string().datetime().optional(),
})
export type CreateEvent = z.infer<typeof CreateEventSchema>

export const SetRsvpSchema = z.object({
  event_id: z.string().uuid(),
  status: RsvpStatusSchema,
})
export type SetRsvp = z.infer<typeof SetRsvpSchema>

export const CheckInSchema = z.object({
  event_id: z.string().uuid(),
  user_id: z.string().uuid(),
})
export type CheckIn = z.infer<typeof CheckInSchema>

export const CloseEventSchema = z.object({
  event_id: z.string().uuid(),
})
export type CloseEvent = z.infer<typeof CloseEventSchema>
