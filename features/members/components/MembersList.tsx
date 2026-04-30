type Member = {
  user_id: string
  role: string
  on_committee: boolean
  turn_order: number | null
  profiles: { display_name: string } | null
}

export default function MembersList({ members }: { members: Member[] }) {
  return (
    <ul className="divide-y rounded-lg border">
      {members.map((m) => (
        <li key={m.user_id} className="flex items-center justify-between p-3">
          <div>
            <p className="font-medium">{m.profiles?.display_name ?? 'Sin nombre'}</p>
            <p className="text-xs text-muted-foreground">
              {m.role === 'admin' ? 'Admin' : 'Miembro'}
              {m.on_committee && ' · Comité'}
              {m.turn_order && ` · Turno ${m.turn_order}`}
            </p>
          </div>
        </li>
      ))}
      {members.length === 0 && (
        <li className="p-4 text-center text-muted-foreground text-sm">Aún sin miembros.</li>
      )}
    </ul>
  )
}
