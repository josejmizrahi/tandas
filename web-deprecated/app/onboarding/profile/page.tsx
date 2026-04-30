import { redirect } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import StepIndicator from '@/components/shell/StepIndicator'
import { createClient } from '@/lib/supabase/server'
import { OnboardingForm } from '@/features/profile'
import { nextOnboardingStep } from '../step'

export default async function OnboardingProfilePage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // If profile already set, advance them
  const next = await nextOnboardingStep(user.id)
  if (next !== '/onboarding/profile') redirect(next)

  const seededName = nullableEmailPrefix(user.email) ?? 'Usuario'
  const { data: profile } = await supabase
    .from('profiles')
    .select('display_name')
    .eq('id', user.id)
    .maybeSingle()

  return (
    <>
      <StepIndicator total={2} current={1} />
      <Card className="w-full">
        <CardHeader className="text-center space-y-2">
          <CardTitle className="text-2xl">¿Cómo te llamas?</CardTitle>
          <CardDescription>Así te van a ver tus amigos en el grupo.</CardDescription>
        </CardHeader>
        <CardContent>
          <OnboardingForm defaultName={profile?.display_name === seededName ? '' : profile?.display_name ?? ''} />
        </CardContent>
      </Card>
    </>
  )
}

function nullableEmailPrefix(email: string | null | undefined): string | undefined {
  if (!email) return undefined
  const prefix = email.split('@')[0]
  return prefix || undefined
}
