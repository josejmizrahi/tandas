import Link from 'next/link'
import { redirect, notFound } from 'next/navigation'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Sparkles, ArrowLeft, Calendar } from 'lucide-react'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import {
  getFine, FineStatusBadge, PayFineButton, AppealFineDialog,
} from '@/features/fines'
import {
  getVote, getMyBallot, getVoteTally, VoteSheet,
} from '@/features/votes'
import { formatMxn } from '@/lib/schemas/money'

function initials(name: string | null): string {
  if (!name) return '?'
  return name.split(/\s+/).slice(0, 2).map((p) => p.charAt(0).toUpperCase()).join('')
}

export default async function FineDetailPage({
  params,
}: { params: Promise<{ gid: string; fid: string }> }) {
  const { gid, fid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, fine] = await Promise.all([
    getGroup(gid),
    getFine(fid),
  ])
  if (!group) notFound()
  if (!fine) notFound()
  if (fine.group_id !== gid) notFound()

  // Resolve display names for the fined user + the issuer
  const userIds = Array.from(new Set([fine.user_id, fine.issued_by].filter(Boolean) as string[]))
  const { data: profiles } = await supabase
    .from('profiles')
    .select('id, display_name')
    .in('id', userIds)
  const byId = new Map((profiles ?? []).map((p) => [p.id, p.display_name]))
  const finedName = byId.get(fine.user_id) ?? 'Sin nombre'
  const issuerName = fine.issued_by ? byId.get(fine.issued_by) ?? null : null

  const isFined = fine.user_id === user.id
  const canPay = isFined && !fine.paid && !fine.waived
  const canAppeal = isFined && !fine.paid && !fine.waived && !fine.appeal_vote_id

  // If there's an appeal vote, fetch it
  let voteBlock: React.ReactNode = null
  if (fine.appeal_vote_id) {
    const [vote, myBallot, tally] = await Promise.all([
      getVote(fine.appeal_vote_id),
      getMyBallot(fine.appeal_vote_id, user.id),
      getVoteTally(fine.appeal_vote_id),
    ])
    if (vote && vote.status === 'open') {
      voteBlock = (
        <section className="space-y-2">
          <h2 className="text-sm font-medium text-muted-foreground px-1">Apelación abierta</h2>
          {vote.description && (
            <Card>
              <CardContent className="p-3 text-sm italic">&ldquo;{vote.description}&rdquo;</CardContent>
            </Card>
          )}
          <VoteSheet
            voteId={vote.id}
            groupId={gid}
            ruleId={null}
            currentChoice={(myBallot?.choice as 'yes' | 'no' | 'abstain' | null) ?? null}
            tally={tally}
            isAdmin={false}
            closesAt={vote.closes_at}
          />
        </section>
      )
    } else if (vote && vote.status !== 'open') {
      voteBlock = (
        <Card>
          <CardContent className="p-4 text-sm text-center">
            Apelación {vote.status === 'passed' ? 'aprobada (multa anulada)' : 'rechazada'}.
          </CardContent>
        </Card>
      )
    }
  }

  const issuedAt = new Intl.DateTimeFormat('es-MX', {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).format(new Date(fine.created_at))

  return (
    <div className="p-4 space-y-6 max-w-md mx-auto">
      <Link
        href={`/g/${gid}/plata`}
        className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
      >
        <ArrowLeft className="size-3.5" /> Volver a Plata
      </Link>

      <Card>
        <CardHeader>
          <div className="flex items-start justify-between gap-2">
            <CardTitle className="text-2xl leading-tight">{formatMxn(fine.amount)}</CardTitle>
            <FineStatusBadge
              paid={fine.paid}
              waived={fine.waived}
              hasOpenAppeal={!!fine.appeal_vote_id && !fine.paid && !fine.waived}
            />
          </div>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex items-start gap-3">
            <Avatar className="size-10">
              <AvatarFallback>{initials(finedName)}</AvatarFallback>
            </Avatar>
            <div className="flex-1 space-y-1">
              <p className="font-medium">{finedName}</p>
              <p className="text-sm">{fine.reason}</p>
            </div>
          </div>

          <div className="flex flex-wrap gap-3 text-xs text-muted-foreground pt-2 border-t">
            <span className="inline-flex items-center gap-1">
              <Calendar className="size-3" /> {issuedAt}
            </span>
            {fine.auto_generated ? (
              <span className="inline-flex items-center gap-1">
                <Sparkles className="size-3" /> Generada automáticamente
              </span>
            ) : issuerName ? (
              <span>Asignada por {issuerName}</span>
            ) : null}
          </div>

          {fine.paid && fine.paid_to_fund && (
            <p className="text-xs text-muted-foreground italic">
              El monto entró al fondo común del grupo.
            </p>
          )}
          {fine.waived && fine.waived_reason && (
            <p className="text-xs text-muted-foreground italic">
              Anulada: {fine.waived_reason}
            </p>
          )}
        </CardContent>
      </Card>

      {voteBlock}

      {canPay && (
        <PayFineButton fineId={fid} groupId={gid} fundEnabled={group.fund_enabled} />
      )}

      {canAppeal && (
        <AppealFineDialog fineId={fid} />
      )}
    </div>
  )
}
