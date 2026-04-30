import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Badge } from '@/components/ui/badge'

type Member = {
  user_id: string
  role: string
  on_committee: boolean
  turn_order: number | null
  profiles: { display_name: string } | null
}

function initials(name: string | null | undefined): string {
  if (!name) return '?'
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((p) => p.charAt(0).toUpperCase())
    .join('')
}

export default function MembersList({ members }: { members: Member[] }) {
  if (members.length === 0) {
    return (
      <div className="rounded-lg border p-6 text-center text-sm text-muted-foreground">
        Aún sin miembros.
      </div>
    )
  }

  return (
    <ul className="divide-y rounded-lg border bg-card">
      {members.map((m) => (
        <li key={m.user_id} className="flex items-center gap-3 p-3">
          <Avatar className="size-9">
            <AvatarFallback>{initials(m.profiles?.display_name)}</AvatarFallback>
          </Avatar>
          <div className="flex-1 min-w-0">
            <p className="font-medium truncate">{m.profiles?.display_name ?? 'Sin nombre'}</p>
            <div className="flex items-center gap-1.5 mt-0.5 flex-wrap">
              {m.role === 'admin' && (
                <Badge variant="secondary" className="text-[10px] px-1.5 py-0 h-4">Admin</Badge>
              )}
              {m.on_committee && (
                <Badge variant="outline" className="text-[10px] px-1.5 py-0 h-4">Comité</Badge>
              )}
              {m.turn_order && (
                <span className="text-xs text-muted-foreground">Turno {m.turn_order}</span>
              )}
            </div>
          </div>
        </li>
      ))}
    </ul>
  )
}
