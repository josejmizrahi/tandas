import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import RuleCard from './RuleCard'
import type { RuleRow } from '../queries'

type RulesListProps = {
  groupId: string
  active: RuleRow[]
  proposed: RuleRow[]
  archived: RuleRow[]
}

export default function RulesList({ groupId, active, proposed, archived }: RulesListProps) {
  return (
    <Tabs defaultValue="active">
      <TabsList className="grid grid-cols-3 w-full">
        <TabsTrigger value="active">Activas ({active.length})</TabsTrigger>
        <TabsTrigger value="proposed">Propuestas ({proposed.length})</TabsTrigger>
        <TabsTrigger value="archived">Archivadas ({archived.length})</TabsTrigger>
      </TabsList>

      <TabsContent value="active" className="space-y-2 mt-4">
        {active.map((r) => <RuleCard key={r.id} groupId={groupId} rule={r} />)}
        {active.length === 0 && (
          <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground">
            Aún no hay reglas activas. Propone la primera.
          </div>
        )}
      </TabsContent>

      <TabsContent value="proposed" className="space-y-2 mt-4">
        {proposed.map((r) => <RuleCard key={r.id} groupId={groupId} rule={r} />)}
        {proposed.length === 0 && (
          <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground">
            No hay reglas en votación.
          </div>
        )}
      </TabsContent>

      <TabsContent value="archived" className="space-y-2 mt-4">
        {archived.map((r) => <RuleCard key={r.id} groupId={groupId} rule={r} />)}
        {archived.length === 0 && (
          <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground">
            Sin reglas archivadas.
          </div>
        )}
      </TabsContent>
    </Tabs>
  )
}
