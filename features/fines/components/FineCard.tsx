import Link from 'next/link'
import { Card, CardContent } from '@/components/ui/card'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Sparkles } from 'lucide-react'
import { formatMxn } from '@/lib/schemas/money'
import FineStatusBadge from './FineStatusBadge'
import type { FineRow, FineWithProfile } from '../queries'

function initials(name: string | null): string {
  if (!name) return '?'
  return name.split(/\s+/).slice(0, 2).map((p) => p.charAt(0).toUpperCase()).join('')
}

type FineCardProps = {
  groupId: string
  fine: FineRow | FineWithProfile
  showWho?: boolean
}

export default function FineCard({ groupId, fine, showWho = false }: FineCardProps) {
  const displayName = 'display_name' in fine ? fine.display_name : null
  return (
    <Link href={`/g/${groupId}/plata/multas/${fine.id}`} className="block">
      <Card className="hover:bg-accent/50 transition-colors">
        <CardContent className="p-4 flex items-start gap-3">
          {showWho && (
            <Avatar className="size-9 shrink-0">
              <AvatarFallback>{initials(displayName)}</AvatarFallback>
            </Avatar>
          )}
          <div className="flex-1 min-w-0 space-y-1">
            <div className="flex items-start justify-between gap-2">
              <p className="font-semibold leading-tight truncate">
                {showWho && displayName ? `${displayName}: ` : ''}{fine.reason}
              </p>
              <FineStatusBadge
                paid={fine.paid}
                waived={fine.waived}
                hasOpenAppeal={!!fine.appeal_vote_id && !fine.paid && !fine.waived}
              />
            </div>
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <span className="font-medium text-foreground">{formatMxn(fine.amount)}</span>
              {fine.auto_generated && (
                <span className="inline-flex items-center gap-1 text-xs">
                  <Sparkles className="size-3" /> Auto
                </span>
              )}
            </div>
          </div>
        </CardContent>
      </Card>
    </Link>
  )
}
