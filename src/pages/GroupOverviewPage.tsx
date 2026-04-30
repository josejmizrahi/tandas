import { useNavigate } from 'react-router-dom'
import { Calendar, FileText, Gavel, Coins, ReceiptText, Users, Vote, Trophy, ArrowLeft } from 'lucide-react'
import { useGroup, useGroupId, useGroupMembers, useMyMembership } from '@/hooks/useGroupContext'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { formatCurrency } from '@/lib/utils'

export function GroupOverviewPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const { data: group, isLoading } = useGroup(groupId)
  const { data: members } = useGroupMembers(groupId)
  const me = useMyMembership(groupId)

  if (isLoading || !group) return <div className="text-sm text-muted-foreground">Cargando…</div>

  const sections: { to: string; label: string; description: string; icon: React.ReactNode }[] = [
    { to: 'tandas', label: `${group.event_label}s`, description: 'Eventos, RSVP, check-in y reglas automáticas', icon: <Calendar className="h-5 w-5" /> },
    { to: 'reglas', label: 'Reglas', description: 'Propuestas, automáticas, excepciones', icon: <FileText className="h-5 w-5" /> },
    { to: 'multas', label: 'Multas', description: 'Pendientes, pagadas, apelaciones', icon: <Gavel className="h-5 w-5" /> },
    { to: 'pots', label: 'Pots de juego', description: 'Poker, Happy King, IOUs al ganador', icon: <Trophy className="h-5 w-5" /> },
    { to: 'gastos', label: 'Gastos', description: 'Splitwise + balances', icon: <ReceiptText className="h-5 w-5" /> },
    { to: 'votaciones', label: 'Votaciones', description: 'Propuestas y apelaciones abiertas', icon: <Vote className="h-5 w-5" /> },
    { to: 'miembros', label: 'Miembros', description: `${members?.length ?? 0} miembros · orden de turnos`, icon: <Users className="h-5 w-5" /> },
  ]

  return (
    <div className="space-y-6">
      <div>
        <Button variant="ghost" size="sm" onClick={() => navigate('/grupos')} className="-ml-3 mb-2">
          <ArrowLeft className="h-4 w-4" /> Mis grupos
        </Button>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-2xl font-semibold">{group.name}</h1>
            <p className="text-sm text-muted-foreground">{group.description ?? `${group.event_label} del grupo`}</p>
            <div className="mt-2 flex flex-wrap gap-2 text-xs">
              <Badge variant="secondary">Código: {group.invite_code}</Badge>
              {me?.role === 'admin' && <Badge>Admin</Badge>}
              {me?.on_committee && <Badge variant="outline">Comité</Badge>}
            </div>
          </div>
          {group.fund_enabled && (
            <Card className="min-w-[200px]">
              <CardHeader className="pb-2">
                <CardDescription>{group.fund_target_label ?? 'Fondo del grupo'}</CardDescription>
                <CardTitle>{formatCurrency(Number(group.fund_balance), group.currency)}</CardTitle>
              </CardHeader>
              {group.fund_target ? (
                <CardContent className="text-xs text-muted-foreground">
                  Meta: {formatCurrency(Number(group.fund_target), group.currency)}
                </CardContent>
              ) : null}
            </Card>
          )}
        </div>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        {sections.map((s) => (
          <Card
            key={s.to}
            role="button"
            onClick={() => navigate(s.to)}
            className="cursor-pointer transition-colors hover:bg-accent"
          >
            <CardHeader className="flex-row items-center gap-3 space-y-0">
              <div className="flex h-10 w-10 items-center justify-center rounded-md bg-muted text-muted-foreground">
                {s.icon}
              </div>
              <div>
                <CardTitle className="text-base">{s.label}</CardTitle>
                <CardDescription>{s.description}</CardDescription>
              </div>
            </CardHeader>
          </Card>
        ))}
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            <Coins className="-mt-0.5 mr-2 inline h-4 w-4" />
            Configuración
          </CardTitle>
        </CardHeader>
        <CardContent className="grid gap-2 text-sm sm:grid-cols-2">
          <Item k="Día por defecto" v={group.default_day_of_week !== null ? dayName(group.default_day_of_week) : '—'} />
          <Item k="Hora" v={group.default_start_time?.slice(0, 5) ?? '—'} />
          <Item k="Ubicación" v={group.default_location ?? '—'} />
          <Item k="Mayoría" v={`${Math.round(group.voting_threshold * 100)}%`} />
          <Item k="Quórum" v={`${Math.round(group.voting_quorum * 100)}%`} />
          <Item k="Duración del voto" v={`${group.vote_duration_hours} h`} />
          <Item k="Rotación de host" v={group.rotation_enabled ? 'Activada' : 'Manual'} />
          <Item k="Bloquear si debe multas" v={group.block_unpaid_attendance ? 'Sí' : 'No'} />
        </CardContent>
      </Card>
    </div>
  )
}

function Item({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex justify-between border-b py-1.5 last:border-0">
      <span className="text-muted-foreground">{k}</span>
      <span className="font-medium">{v}</span>
    </div>
  )
}

function dayName(d: number) {
  return ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'][d]
}
