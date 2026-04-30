import Link from 'next/link'
import { Card, CardContent } from '@/components/ui/card'
import { AlertTriangle } from 'lucide-react'
import { formatMxn } from '@/lib/schemas/money'
import type { FineRow } from '../queries'

export default function PendingFinesAlert({
  groupId, fines,
}: { groupId: string; fines: FineRow[] }) {
  if (fines.length === 0) return null

  const total = fines.reduce((sum, f) => sum + Number(f.amount), 0)

  return (
    <Link href={`/g/${groupId}/plata`} className="block">
      <Card className="glass border-destructive/30 hover:bg-destructive/10 transition-colors">
        <CardContent className="p-4 flex items-center gap-3">
          <div className="flex size-10 items-center justify-center rounded-lg bg-destructive/15 text-destructive shrink-0">
            <AlertTriangle className="size-5" />
          </div>
          <div className="flex-1">
            <p className="font-medium text-sm">
              {fines.length} {fines.length === 1 ? 'multa' : 'multas'} por pagar
            </p>
            <p className="text-xs text-muted-foreground">
              Debes {formatMxn(total)}
            </p>
          </div>
        </CardContent>
      </Card>
    </Link>
  )
}
