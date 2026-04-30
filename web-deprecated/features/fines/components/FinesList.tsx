import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import FineCard from './FineCard'
import type { FineRow, FineWithProfile } from '../queries'

type FinesListProps = {
  groupId: string
  myFines: FineRow[]
  groupFines: FineWithProfile[]
}

function unpaid(f: FineRow) { return !f.paid && !f.waived }

export default function FinesList({ groupId, myFines, groupFines }: FinesListProps) {
  const myUnpaid = myFines.filter(unpaid)
  const myHistory = myFines.filter((f) => !unpaid(f))
  const groupUnpaid = groupFines.filter(unpaid)

  return (
    <Tabs defaultValue="mine">
      <TabsList className="grid grid-cols-2 w-full">
        <TabsTrigger value="mine">Mías ({myUnpaid.length})</TabsTrigger>
        <TabsTrigger value="all">Todas ({groupUnpaid.length})</TabsTrigger>
      </TabsList>

      <TabsContent value="mine" className="space-y-2 mt-4">
        {myUnpaid.length > 0 && (
          <>
            <p className="text-xs text-muted-foreground px-1">Por pagar</p>
            {myUnpaid.map((f) => <FineCard key={f.id} groupId={groupId} fine={f} />)}
          </>
        )}
        {myHistory.length > 0 && (
          <>
            <p className="text-xs text-muted-foreground px-1 pt-2">Historial</p>
            {myHistory.map((f) => <FineCard key={f.id} groupId={groupId} fine={f} />)}
          </>
        )}
        {myFines.length === 0 && (
          <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground">
            Sin multas. Bien ahí.
          </div>
        )}
      </TabsContent>

      <TabsContent value="all" className="space-y-2 mt-4">
        {groupFines.map((f) => (
          <FineCard key={f.id} groupId={groupId} fine={f} showWho />
        ))}
        {groupFines.length === 0 && (
          <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground">
            Aún no hay multas en el grupo.
          </div>
        )}
      </TabsContent>
    </Tabs>
  )
}
