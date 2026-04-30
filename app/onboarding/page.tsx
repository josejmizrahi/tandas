import { redirect } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { createClient } from '@/lib/supabase/server'
import { OnboardingForm } from '@/features/profile'

export default async function OnboardingPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: profile } = await supabase
    .from('profiles')
    .select('display_name')
    .eq('id', user.id)
    .maybeSingle()

  const seededName = nullableEmailPrefix(user.email) ?? 'Usuario'
  if (profile?.display_name && profile.display_name !== seededName) {
    redirect('/')
  }

  const defaultName = profile?.display_name ?? seededName

  return (
    <main className="min-h-dvh flex flex-col items-center justify-center p-6 bg-muted/30">
      <Card className="w-full max-w-sm">
        <CardHeader className="text-center space-y-2">
          <CardTitle className="text-2xl">Bienvenido</CardTitle>
          <CardDescription>¿Cómo quieres aparecer en tus grupos?</CardDescription>
        </CardHeader>
        <CardContent>
          <OnboardingForm defaultName={defaultName} />
        </CardContent>
      </Card>
    </main>
  )
}

function nullableEmailPrefix(email: string | undefined): string | undefined {
  if (!email) return undefined
  const prefix = email.split('@')[0]
  return prefix || undefined
}
