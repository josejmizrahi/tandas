import Link from 'next/link'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Calendar, MapPin } from 'lucide-react'
import { formatEventDate } from '@/lib/dates'
import RsvpToggle from './RsvpToggle'

type NextEventCardProps = {
  groupId: string
  timezone: string
  event: {
    id: string
    starts_at: string
    location: string | null
    title: string | null
    status: string
  } | null
  myRsvp: 'pending' | 'going' | 'maybe' | 'declined' | null
}

export default function NextEventCard({ groupId, timezone, event, myRsvp }: NextEventCardProps) {
  if (!event) {
    return (
      <Card className="glass-subtle">
        <CardContent className="p-6 text-center text-sm text-muted-foreground">
          No hay eventos próximos. Si eres admin, créa uno desde la pestaña Eventos.
        </CardContent>
      </Card>
    )
  }

  return (
    <Card className="glass">
      <CardHeader>
        <CardTitle>Próximo evento</CardTitle>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <Calendar className="size-4 text-muted-foreground" />
            <span className="font-medium capitalize">{formatEventDate(event.starts_at, timezone)}</span>
          </div>
          {event.title && <p className="text-lg font-semibold">{event.title}</p>}
          {event.location && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <MapPin className="size-4 shrink-0" />
              <span>{event.location}</span>
            </div>
          )}
        </div>

        <div className="space-y-2">
          <p className="text-sm font-medium">¿Vas a ir?</p>
          <RsvpToggle eventId={event.id} groupId={groupId} currentStatus={myRsvp ?? 'pending'} />
        </div>

        <Link
          href={`/g/${groupId}/eventos/${event.id}`}
          className="block text-center text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          Ver detalle →
        </Link>
      </CardContent>
    </Card>
  )
}
