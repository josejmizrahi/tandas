import { Progress } from '@/components/ui/progress'
import type { VoteTally } from '../queries'

export default function VoteTallyBar({ tally }: { tally: VoteTally }) {
  const yesPct = tally.eligible > 0 ? (tally.yes / tally.eligible) * 100 : 0
  const totalPct = tally.eligible > 0 ? (tally.total / tally.eligible) * 100 : 0
  const quorumPct = tally.quorum * 100
  const thresholdPct = tally.threshold * 100

  const passYes = tally.yes + tally.no > 0 ? (tally.yes / (tally.yes + tally.no)) >= tally.threshold : false
  const passQuorum = totalPct >= quorumPct

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between text-xs">
        <span className="font-medium">Votación</span>
        <span className="text-muted-foreground">
          {tally.total}/{tally.eligible} votaron
        </span>
      </div>
      <Progress value={yesPct} className="h-2" />
      <div className="grid grid-cols-3 text-xs gap-2">
        <span className="text-emerald-600">Sí: {tally.yes}</span>
        <span className="text-destructive">No: {tally.no}</span>
        <span className="text-muted-foreground">Abstención: {tally.abstain}</span>
      </div>
      <p className="text-xs text-muted-foreground pt-1">
        Quórum {quorumPct.toFixed(0)}% {passQuorum ? '✓' : '✗'} · Umbral {thresholdPct.toFixed(0)}% Sí {passYes ? '✓' : '✗'}
      </p>
    </div>
  )
}
