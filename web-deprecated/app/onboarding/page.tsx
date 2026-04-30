import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { nextOnboardingStep } from './step'

export default async function OnboardingIndexPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  redirect(await nextOnboardingStep(user.id))
}
