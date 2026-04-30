import { Badge } from '@/components/ui/badge'

export default function FineStatusBadge({
  paid, waived, hasOpenAppeal,
}: { paid: boolean; waived: boolean; hasOpenAppeal: boolean }) {
  if (waived) return <Badge variant="outline">Anulada</Badge>
  if (paid)   return <Badge variant="secondary">Pagada</Badge>
  if (hasOpenAppeal) return <Badge variant="outline">En apelación</Badge>
  return <Badge variant="destructive">Por pagar</Badge>
}
