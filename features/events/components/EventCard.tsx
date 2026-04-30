import Link from 'next/link'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Calendar, MapPin } from 'lucide-react'
import { formatEventDate } from '@/lib/dates'

type EventCardProps = {
  groupId: string
  event: {
    id: string
    starts_at: string
    location: string | null
    title: string | null
    status: string
  }
  timezone: string
}

export default function EventCard({ groupId, event, timezone }: EventCardProps) {
  const isCompleted = event.status === 'completed'
  return (
    <Link href={`/g/${groupId}/eventos/${event.id}`} className="block">
      <Card className={isCompleted ? 'opacity-70' : 'hover:bg-accent/50 transition-colors'}>
        <CardContent className="p-4 space-y-2">
          <div className="flex items-center gap-2 text-sm">
            <Calendar className="size-4 text-muted-foreground" />
            <span className="font-medium capitalize">{formatEventDate(event.starts_at, timezone)}</span>
          </div>
          {event.title && <p className="font-semibold leading-tight">{event.title}</p>}
          {event.location && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <MapPin className="size-3.5 shrink-0" />
              <span className="truncate">{event.location}</span>
            </div>
          )}
          {isCompleted && (
            <Badge variant="secondary" className="text-[10px] px-1.5 py-0 h-4">Cerrado</Badge>
          )}
        </CardContent>
      </Card>
    </Link>
  )
}
