import Link from 'next/link'
import { redirect } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Plus, Hash, Users } from 'lucide-react'
import { createClient } from '@/lib/supabase/server'
import { nextOnboardingStep } from './onboarding/step'

export default async function HomePage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Single source of truth for onboarding routing
  const next = await nextOnboardingStep(user.id)
  if (next !== '/') redirect(next)

  // Multi-group picker (≥2 groups)
  const { data: memberships } = await supabase
    .from('group_members')
    .select('group_id, groups(id, name)')
    .eq('user_id', user.id)
    .eq('active', true)

  return (
    <main className="min-h-dvh flex flex-col items-center justify-center bg-muted/30 p-6">
      <div className="w-full max-w-sm space-y-4">
        <div className="flex flex-col items-center gap-2 text-center mb-2">
          <div className="flex size-12 items-center justify-center rounded-xl bg-primary/10 text-primary">
            <Users className="size-6" />
          </div>
          <h1 className="text-xl font-bold">Tus grupos</h1>
        </div>

        <ul className="space-y-2">
          {memberships?.map((m) => (
            <li key={m.group_id}>
              <Link href={`/g/${m.group_id}`} className="block">
                <Card className="hover:bg-accent/50 transition-colors">
                  <CardContent className="p-4">
                    <p className="font-medium">{m.groups?.name ?? 'Grupo'}</p>
                  </CardContent>
                </Card>
              </Link>
            </li>
          ))}
        </ul>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">¿Otro grupo?</CardTitle>
            <CardDescription className="text-xs">
              Puedes estar en varios grupos a la vez.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            <Button asChild variant="outline" className="w-full justify-start">
              <Link href="/g/new"><Plus className="size-4 mr-2" /> Crear grupo nuevo</Link>
            </Button>
            <Button asChild variant="outline" className="w-full justify-start">
              <Link href="/g/join"><Hash className="size-4 mr-2" /> Unirme con código</Link>
            </Button>
          </CardContent>
        </Card>
      </div>
    </main>
  )
}
