import { redirect } from 'next/navigation'
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

  // Skip onboarding if profile name has been customized
  // (handle_new_user trigger seeds it from email prefix or 'Usuario')
  const seededName = nullableEmailPrefix(user.email) ?? 'Usuario'
  if (profile?.display_name && profile.display_name !== seededName) {
    redirect('/')
  }

  const defaultName = profile?.display_name ?? seededName

  return (
    <main className="min-h-dvh flex flex-col items-center justify-center p-6 gap-8">
      <div className="text-center space-y-2">
        <h1 className="text-2xl font-bold">Bienvenido</h1>
        <p className="text-muted-foreground">¿Cómo quieres aparecer en tus grupos?</p>
      </div>
      <OnboardingForm defaultName={defaultName} />
    </main>
  )
}

function nullableEmailPrefix(email: string | undefined): string | undefined {
  if (!email) return undefined
  const prefix = email.split('@')[0]
  return prefix || undefined
}
