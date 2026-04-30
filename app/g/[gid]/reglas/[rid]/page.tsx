import { redirect, notFound } from 'next/navigation'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { getRule, RuleStatusBadge, RuleExceptionsEditor, RuleArchiveDialog } from '@/features/rules'
import { isAdminOfGroup } from '@/features/events'
import { listGroupMembers } from '@/features/members'
import { getVote, getMyBallot, getVoteTally, VoteSheet } from '@/features/votes'
import { formatMxn } from '@/lib/schemas/money'

function getAmount(action: unknown): number | null {
  if (typeof action !== 'object' || action === null) return null
  const a = action as { params?: { amount?: number } }
  return typeof a.params?.amount === 'number' ? a.params.amount : null
}

function getExceptionUserIds(exceptions: unknown): string[] {
  if (!Array.isArray(exceptions)) return []
  return exceptions
    .map((e) => (typeof e === 'object' && e !== null ? (e as { user_id?: unknown }).user_id : undefined))
    .filter((u): u is string => typeof u === 'string')
}

export default async function RuleDetailPage({
  params,
}: { params: Promise<{ gid: string; rid: string }> }) {
  const { gid, rid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, rule, isAdmin, members] = await Promise.all([
    getGroup(gid),
    getRule(rid),
    isAdminOfGroup(gid, user.id),
    listGroupMembers(gid),
  ])
  if (!group) notFound()
  if (!rule) notFound()
  if (rule.group_id !== gid) notFound()

  const amount = getAmount(rule.action)
  const exceptionIds = getExceptionUserIds(rule.exceptions)

  // If proposed, fetch the open vote
  let voteBlock: React.ReactNode = null
  if (rule.status === 'proposed' && rule.approved_via_vote_id) {
    const [vote, myBallot, tally] = await Promise.all([
      getVote(rule.approved_via_vote_id),
      getMyBallot(rule.approved_via_vote_id, user.id),
      getVoteTally(rule.approved_via_vote_id),
    ])
    if (vote && vote.status === 'open') {
      voteBlock = (
        <section className="space-y-2">
          <h2 className="text-sm font-medium text-muted-foreground px-1">Votación abierta</h2>
          <VoteSheet
            voteId={vote.id}
            groupId={gid}
            ruleId={rid}
            currentChoice={(myBallot?.choice as 'yes' | 'no' | 'abstain' | null) ?? null}
            tally={tally}
            isAdmin={isAdmin}
            closesAt={vote.closes_at}
          />
        </section>
      )
    } else if (vote && vote.status !== 'open') {
      voteBlock = (
        <Card>
          <CardContent className="p-4 text-sm text-center">
            Votación {vote.status === 'passed' ? 'aprobada' : vote.status === 'rejected' ? 'rechazada' : 'cerrada'}.
          </CardContent>
        </Card>
      )
    }
  }

  return (
    <div className="p-4 space-y-6 max-w-md mx-auto">
      <Card>
        <CardHeader>
          <div className="flex items-start justify-between gap-2">
            <CardTitle className="leading-tight">{rule.title}</CardTitle>
            <RuleStatusBadge status={rule.status} />
          </div>
        </CardHeader>
        <CardContent className="space-y-2">
          {rule.description && <p className="text-sm">{rule.description}</p>}
          {amount !== null && (
            <Badge variant="secondary" className="font-normal">
              Multa: {formatMxn(amount)}
            </Badge>
          )}
        </CardContent>
      </Card>

      {voteBlock}

      {isAdmin && rule.status === 'active' && (
        <section className="space-y-2">
          <h2 className="text-sm font-medium text-muted-foreground px-1">Excepciones</h2>
          <p className="text-xs text-muted-foreground px-1">
            Miembros marcados quedan exentos de esta regla.
          </p>
          <RuleExceptionsEditor
            ruleId={rid}
            groupId={gid}
            members={members.map((m) => ({
              user_id: m.user_id,
              display_name: m.profiles?.display_name ?? null,
            }))}
            currentExceptions={exceptionIds}
          />
        </section>
      )}

      {isAdmin && rule.status === 'active' && (
        <section>
          <RuleArchiveDialog ruleId={rid} groupId={gid} />
        </section>
      )}
    </div>
  )
}
