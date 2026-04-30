import Link from 'next/link'
import { Card, CardContent } from '@/components/ui/card'
import RuleStatusBadge from './RuleStatusBadge'
import { formatMxn } from '@/lib/schemas/money'

type RuleCardProps = {
  groupId: string
  rule: {
    id: string
    title: string
    description: string | null
    status: string
    action: unknown
  }
}

function getAmount(action: unknown): number | null {
  if (typeof action !== 'object' || action === null) return null
  const a = action as { params?: { amount?: number } }
  return typeof a.params?.amount === 'number' ? a.params.amount : null
}

export default function RuleCard({ groupId, rule }: RuleCardProps) {
  const amount = getAmount(rule.action)
  return (
    <Link href={`/g/${groupId}/reglas/${rule.id}`} className="block">
      <Card className="hover:bg-accent/50 transition-colors">
        <CardContent className="p-4 space-y-2">
          <div className="flex items-start justify-between gap-2">
            <p className="font-semibold leading-tight">{rule.title}</p>
            <RuleStatusBadge status={rule.status} />
          </div>
          {rule.description && (
            <p className="text-sm text-muted-foreground line-clamp-2">{rule.description}</p>
          )}
          {amount !== null && (
            <p className="text-xs text-muted-foreground">Multa: {formatMxn(amount)}</p>
          )}
        </CardContent>
      </Card>
    </Link>
  )
}
