import { Badge } from '@/components/ui/badge'

const VARIANTS: Record<string, { label: string; variant: 'default' | 'secondary' | 'outline' | 'destructive' }> = {
  active:   { label: 'Activa',    variant: 'default' },
  proposed: { label: 'Propuesta', variant: 'secondary' },
  archived: { label: 'Archivada', variant: 'outline' },
}

export default function RuleStatusBadge({ status }: { status: string }) {
  const v = VARIANTS[status] ?? { label: status, variant: 'outline' as const }
  return <Badge variant={v.variant}>{v.label}</Badge>
}
