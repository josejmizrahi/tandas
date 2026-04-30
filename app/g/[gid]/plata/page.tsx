import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

export default function PlataPage() {
  return (
    <div className="p-4 max-w-md mx-auto space-y-4">
      <h1 className="text-xl font-bold">Plata</h1>
      <Card>
        <CardHeader>
          <CardTitle>Próximamente</CardTitle>
          <CardDescription>
            Phase 4: multas (auto + manual + apelación), balance unificado, settle up.
          </CardDescription>
        </CardHeader>
        <CardContent />
      </Card>
    </div>
  )
}
