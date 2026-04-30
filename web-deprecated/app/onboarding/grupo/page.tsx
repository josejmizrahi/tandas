import Link from 'next/link'
import { redirect } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Plus, Hash } from 'lucide-react'
import StepIndicator from '@/components/shell/StepIndicator'
import { createClient } from '@/lib/supabase/server'
import { nextOnboardingStep } from '../step'

export default async function OnboardingGrupoPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const next = await nextOnboardingStep(user.id)
  if (next !== '/onboarding/grupo') redirect(next)

  return (
    <>
      <StepIndicator total={2} current={2} />
      <Card className="w-full">
        <CardHeader className="text-center space-y-2">
          <CardTitle className="text-2xl">Tu primer grupo</CardTitle>
          <CardDescription>
            Crea uno desde cero o únete a uno con código de invitación.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <Button asChild className="w-full justify-start h-auto py-4" size="lg">
            <Link href="/g/new">
              <div className="flex items-start gap-3 text-left">
                <Plus className="size-5 mt-0.5 shrink-0" />
                <div className="space-y-0.5">
                  <p className="font-semibold">Crear grupo nuevo</p>
                  <p className="text-xs opacity-80 font-normal">
                    Tú eres el admin. Invitas a tus amigos con un código.
                  </p>
                </div>
              </div>
            </Link>
          </Button>

          <Button asChild variant="outline" className="w-full justify-start h-auto py-4" size="lg">
            <Link href="/g/join">
              <div className="flex items-start gap-3 text-left">
                <Hash className="size-5 mt-0.5 shrink-0 text-muted-foreground" />
                <div className="space-y-0.5">
                  <p className="font-semibold">Unirme con código</p>
                  <p className="text-xs text-muted-foreground font-normal">
                    Pega el código que te pasaron por WhatsApp.
                  </p>
                </div>
              </div>
            </Link>
          </Button>
        </CardContent>
      </Card>
    </>
  )
}
