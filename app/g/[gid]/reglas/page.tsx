import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

export default function ReglasPage() {
  return (
    <div className="p-4 max-w-md mx-auto space-y-4">
      <h1 className="text-xl font-bold">Reglas</h1>
      <Card>
        <CardHeader>
          <CardTitle>Próximamente</CardTitle>
          <CardDescription>
            Phase 3: propuesta de reglas, votación, y motor de aplicación automático.
          </CardDescription>
        </CardHeader>
        <CardContent />
      </Card>
    </div>
  )
}
