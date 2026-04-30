import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Calendar, MapPin } from 'lucide-react'
import { formatEventDate } from '@/lib/dates'
import RsvpToggle from './RsvpToggle'
import AttendanceList from './AttendanceList'
import CheckInButton from './CheckInButton'
import CloseEventDialog from './CloseEventDialog'
import type { AttendanceWithProfile } from '../queries'

type EventDetailProps = {
  groupId: string
  timezone: string
  isAdmin: boolean
  currentUserId: string
  event: {
    id: string
    starts_at: string
    location: string | null
    title: string | null
    status: string
    cycle_number: number | null
  }
  attendance: AttendanceWithProfile[]
  myAttendance: AttendanceWithProfile | undefined
}

export default function EventDetail({
  groupId, timezone, isAdmin, currentUserId, event, attendance, myAttendance,
}: EventDetailProps) {
  const isClosed = event.status === 'completed'
  const myRsvp = (myAttendance?.rsvp_status ?? 'pending') as 'pending' | 'going' | 'maybe' | 'declined'
  const alreadyCheckedIn = !!myAttendance?.arrived_at

  return (
    <div className="p-4 space-y-6 max-w-md mx-auto">
      <Card>
        <CardHeader>
          <div className="flex items-start justify-between gap-2">
            <CardTitle className="leading-tight">
              {event.title ?? `Evento #${event.cycle_number ?? '?'}`}
            </CardTitle>
            {isClosed && (
              <Badge variant="secondary" className="shrink-0">Cerrado</Badge>
            )}
          </div>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex items-center gap-2">
            <Calendar className="size-4 text-muted-foreground" />
            <span className="font-medium capitalize">{formatEventDate(event.starts_at, timezone)}</span>
          </div>
          {event.location && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <MapPin className="size-4 shrink-0" />
              <span>{event.location}</span>
            </div>
          )}
        </CardContent>
      </Card>

      {!isClosed && (
        <section className="space-y-2">
          <p className="text-sm font-medium px-1">Mi RSVP</p>
          <RsvpToggle eventId={event.id} groupId={groupId} currentStatus={myRsvp} />
        </section>
      )}

      {!isClosed && myRsvp === 'going' && (
        <section>
          <CheckInButton
            eventId={event.id}
            userId={currentUserId}
            groupId={groupId}
            alreadyCheckedIn={alreadyCheckedIn}
          />
        </section>
      )}

      <section className="space-y-2">
        <h2 className="text-sm font-medium text-muted-foreground px-1">Asistencia ({attendance.length})</h2>
        <AttendanceList attendance={attendance} />
      </section>

      {isAdmin && !isClosed && (
        <section>
          <CloseEventDialog eventId={event.id} groupId={groupId} />
        </section>
      )}
    </div>
  )
}
