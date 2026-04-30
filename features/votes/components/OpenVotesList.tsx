import Link from 'next/link'
import { Card, CardContent } from '@/components/ui/card'
import { Vote } from 'lucide-react'
import type { OpenVoteRow } from '../queries'

const SUBJECT_LABEL: Record<string, string> = {
  rule_proposal: 'Propuesta de regla',
  rule_repeal:   'Derogación de regla',
  fine_appeal:   'Apelación de multa',
  host_swap:     'Cambio de anfitrión',
  general:       'Votación general',
}

export default function OpenVotesList({
  groupId, votes,
}: { groupId: string; votes: OpenVoteRow[] }) {
  if (votes.length === 0) return null

  return (
    <section className="space-y-2">
      <div className="flex items-center gap-2 px-1">
        <Vote className="size-4 text-muted-foreground" />
        <h2 className="text-sm font-medium text-muted-foreground">
          Te falta votar ({votes.length})
        </h2>
      </div>
      <ul className="space-y-2">
        {votes.map((v) => {
          const href = v.subject_type === 'rule_proposal' && v.subject_id
            ? `/g/${groupId}/reglas/${v.subject_id}`
            : `/g/${groupId}/reglas` // fallback; fine_appeal etc come in Phase 4
          return (
            <li key={v.id}>
              <Link href={href} className="block">
                <Card className="hover:bg-accent/50 transition-colors">
                  <CardContent className="p-3">
                    <p className="font-medium text-sm leading-tight">{v.title}</p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {SUBJECT_LABEL[v.subject_type] ?? v.subject_type}
                    </p>
                  </CardContent>
                </Card>
              </Link>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
