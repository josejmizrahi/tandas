import Link from 'next/link'
import { redirect, notFound } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Calendar, Scale, ShieldCheck, ArrowRight } from 'lucide-react'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { listGroupMembers } from '@/features/members'
import { listActiveRules } from '@/features/rules'
import { getNextEventForGroup } from '@/features/events'
import { formatEventDate } from '@/lib/dates'
import { formatMxn } from '@/lib/schemas/money'

function initials(name: string | null): string {
  if (!name) return '?'
  return name.split(/\s+/).slice(0, 2).map((p) => p.charAt(0).toUpperCase()).join('')
}

function getRuleAmount(action: unknown): number | null {
  if (typeof action !== 'object' || action === null) return null
  const a = action as { params?: { amount?: number } }
  return typeof a.params?.amount === 'number' ? a.params.amount : null
}

export default async function BienvenidaPage({
  params,
}: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [
    group,
    members,
    activeRules,
    nextEvent,
    { count: totalEvents },
  ] = await Promise.all([
    getGroup(gid),
    listGroupMembers(gid),
    listActiveRules(gid),
    getNextEventForGroup(gid),
    supabase.from('events').select('id', { count: 'exact', head: true }).eq('group_id', gid),
  ])
  if (!group) notFound()

  // Verify user is a member
  const myMembership = members.find((m) => m.user_id === user.id)
  if (!myMembership) notFound()

  // Read group settings to know grace period and timezone
  const { data: groupFull } = await supabase
    .from('groups')
    .select('grace_period_events, event_label, timezone, created_at')
    .eq('id', gid)
    .single()
  const gracePeriod = groupFull?.grace_period_events ?? 0
  const eventLabel = groupFull?.event_label ?? group.event_label ?? 'evento'
  const tz = groupFull?.timezone ?? 'America/Mexico_City'
  const foundedAt = groupFull?.created_at
    ? new Intl.DateTimeFormat('es-MX', { day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(groupFull.created_at))
    : null

  // Top 3 senior members (besides me) by joined_at — already ordered by turn_order;
  // for tour we want oldest-joined first. Re-sort.
  const senior = [...members]
    .filter((m) => m.user_id !== user.id)
    .slice(0, 3)

  const topRules = activeRules.slice(0, 3)

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <Card>
        <CardHeader className="text-center space-y-2">
          <CardTitle className="text-2xl">¡Bienvenido a {group.name}!</CardTitle>
          <CardDescription>
            {totalEvents !== null && totalEvents > 0
              ? `${totalEvents} ${eventLabel.toLowerCase()}${totalEvents === 1 ? '' : 's'} registrado${totalEvents === 1 ? '' : 's'}`
              : 'El grupo está empezando'}
            {foundedAt && ` · desde ${foundedAt}`}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {/* Grace period */}
          {gracePeriod > 0 && (
            <div className="flex items-start gap-3 rounded-lg border border-emerald-300/30 bg-emerald-50/50 dark:bg-emerald-950/30 p-3">
              <ShieldCheck className="size-5 text-emerald-600 shrink-0 mt-0.5" />
              <div className="space-y-0.5">
                <p className="font-medium text-sm">Período de gracia</p>
                <p className="text-xs text-muted-foreground">
                  Tienes {gracePeriod} {eventLabel.toLowerCase()}{gracePeriod === 1 ? '' : 's'} antes de que apliquen multas automáticas. Tranquilo, sin presión.
                </p>
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Senior members */}
      {senior.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Quién está en el grupo</CardTitle>
          </CardHeader>
          <CardContent>
            <ul className="divide-y">
              {senior.map((m) => (
                <li key={m.user_id} className="flex items-center gap-3 py-2 first:pt-0 last:pb-0">
                  <Avatar className="size-9">
                    <AvatarFallback>{initials(m.profiles?.display_name ?? null)}</AvatarFallback>
                  </Avatar>
                  <div className="flex-1 min-w-0">
                    <p className="font-medium text-sm truncate">{m.profiles?.display_name ?? 'Sin nombre'}</p>
                    <div className="flex items-center gap-1.5 mt-0.5">
                      {m.role === 'admin' && <Badge variant="secondary" className="text-[10px] px-1.5 py-0 h-4">Admin</Badge>}
                      {m.on_committee && <Badge variant="outline" className="text-[10px] px-1.5 py-0 h-4">Comité</Badge>}
                    </div>
                  </div>
                </li>
              ))}
            </ul>
            {members.length > 3 && (
              <p className="text-xs text-muted-foreground text-center pt-3">
                Y {members.length - 3} más. Vas a verlos en /Más → Miembros.
              </p>
            )}
          </CardContent>
        </Card>
      )}

      {/* Active rules */}
      {topRules.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base flex items-center gap-2">
              <Scale className="size-4 text-muted-foreground" />
              Reglas que aplican
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ul className="space-y-2.5">
              {topRules.map((r) => {
                const amount = getRuleAmount(r.action)
                return (
                  <li key={r.id} className="space-y-0.5">
                    <p className="font-medium text-sm">{r.title}</p>
                    {amount !== null && (
                      <p className="text-xs text-muted-foreground">Multa: {formatMxn(amount)}</p>
                    )}
                  </li>
                )
              })}
            </ul>
            {activeRules.length > 3 && (
              <p className="text-xs text-muted-foreground pt-3">
                Y {activeRules.length - 3} más en /Reglas.
              </p>
            )}
          </CardContent>
        </Card>
      )}

      {/* Next event */}
      {nextEvent && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base flex items-center gap-2">
              <Calendar className="size-4 text-muted-foreground" />
              Tu primer {eventLabel.toLowerCase()}
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="font-medium capitalize">{formatEventDate(nextEvent.starts_at, tz)}</p>
            {nextEvent.location && (
              <p className="text-sm text-muted-foreground mt-1">{nextEvent.location}</p>
            )}
          </CardContent>
        </Card>
      )}

      <Button asChild size="lg" className="w-full">
        <Link href={`/g/${gid}/hoy`}>
          Entrar al grupo
          <ArrowRight className="size-4 ml-2" />
        </Link>
      </Button>
    </div>
  )
}
