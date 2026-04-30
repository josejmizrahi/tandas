import { useQuery } from '@tanstack/react-query'
import { Link, useNavigate } from 'react-router-dom'
import { Plus, KeyRound, Calendar, Users } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { EmptyState } from '@/components/ui/empty-state'

export function GroupsListPage() {
  const navigate = useNavigate()
  const { data, isLoading } = useQuery({
    queryKey: ['groups'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('groups')
        .select('*')
        .order('created_at', { ascending: false })
      if (error) throw error
      return data
    },
  })

  if (isLoading) return <div className="text-sm text-muted-foreground">Cargando…</div>

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Mis grupos</h1>
          <p className="text-sm text-muted-foreground">Administra tus tandas, reuniones o cenas.</p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" onClick={() => navigate('/grupos/unirse')}>
            <KeyRound className="h-4 w-4" />
            Unirme
          </Button>
          <Button onClick={() => navigate('/grupos/nuevo')}>
            <Plus className="h-4 w-4" />
            Nuevo
          </Button>
        </div>
      </div>

      {!data?.length ? (
        <EmptyState
          icon={<Users className="h-8 w-8" />}
          title="Aún no tienes grupos"
          description="Crea uno nuevo o únete con un código de invitación."
          action={
            <div className="flex gap-2">
              <Button variant="outline" onClick={() => navigate('/grupos/unirse')}>
                <KeyRound className="h-4 w-4" /> Unirme
              </Button>
              <Button onClick={() => navigate('/grupos/nuevo')}>
                <Plus className="h-4 w-4" /> Crear grupo
              </Button>
            </div>
          }
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2">
          {data.map((g) => (
            <Link key={g.id} to={`/grupos/${g.id}`}>
              <Card className="transition-colors hover:bg-accent">
                <CardHeader>
                  <CardTitle>{g.name}</CardTitle>
                  <CardDescription>
                    {g.event_label} · {g.currency}
                  </CardDescription>
                </CardHeader>
                <CardContent className="text-sm text-muted-foreground">
                  <div className="flex items-center gap-2">
                    <Calendar className="h-4 w-4" />
                    {g.default_day_of_week !== null
                      ? `Cada ${dayName(g.default_day_of_week)}`
                      : 'Sin día fijo'}
                    {g.default_start_time && ` · ${g.default_start_time.slice(0, 5)}`}
                  </div>
                  {g.fund_enabled && (
                    <div className="mt-1">Fondo: {g.currency} {g.fund_balance.toFixed(2)}</div>
                  )}
                </CardContent>
              </Card>
            </Link>
          ))}
        </div>
      )}
    </div>
  )
}

function dayName(d: number) {
  return ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'][d]
}
