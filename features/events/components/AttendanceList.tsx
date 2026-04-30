import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Badge } from '@/components/ui/badge'
import { CheckCircle2, XCircle, Clock } from 'lucide-react'
import type { AttendanceWithProfile } from '../queries'

const STATUS_LABEL: Record<string, string> = {
  going: 'Voy',
  maybe: 'Tal vez',
  declined: 'No voy',
  pending: 'Sin responder',
}

function initials(name: string | null): string {
  if (!name) return '?'
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((p) => p.charAt(0).toUpperCase())
    .join('')
}

export default function AttendanceList({ attendance }: { attendance: AttendanceWithProfile[] }) {
  if (attendance.length === 0) {
    return (
      <div className="rounded-lg border p-6 text-center text-sm text-muted-foreground">
        Aún sin RSVPs.
      </div>
    )
  }

  return (
    <ul className="divide-y rounded-lg border bg-card">
      {attendance.map((a) => (
        <li key={a.user_id} className="flex items-center gap-3 p-3">
          <Avatar className="size-9">
            <AvatarFallback>{initials(a.display_name)}</AvatarFallback>
          </Avatar>
          <div className="flex-1 min-w-0">
            <p className="font-medium truncate">{a.display_name ?? 'Sin nombre'}</p>
            <div className="flex items-center gap-1.5 mt-0.5 flex-wrap text-xs text-muted-foreground">
              <span>{STATUS_LABEL[a.rsvp_status] ?? a.rsvp_status}</span>
              {a.cancelled_same_day && <Badge variant="outline" className="text-[10px] px-1.5 py-0 h-4">Canceló mismo día</Badge>}
            </div>
          </div>
          <div className="shrink-0">
            {a.arrived_at ? (
              <CheckCircle2 className="size-5 text-emerald-600" aria-label="Llegó" />
            ) : a.no_show ? (
              <XCircle className="size-5 text-destructive" aria-label="No-show" />
            ) : a.rsvp_status === 'pending' ? (
              <Clock className="size-5 text-muted-foreground" aria-label="Sin responder" />
            ) : null}
          </div>
        </li>
      ))}
    </ul>
  )
}
