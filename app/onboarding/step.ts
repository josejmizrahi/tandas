import 'server-only'
import { createClient } from '@/lib/supabase/server'

/**
 * Returns the next onboarding step path the given user should land on.
 * - No display_name set OR seed name → /onboarding/profile
 * - Profile set + 0 active groups → /onboarding/grupo
 * - Profile set + ≥1 active groups → /g/[gid]/hoy (or picker if multi)
 */
export async function nextOnboardingStep(userId: string): Promise<string> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  const seededName = nullableEmailPrefix(user?.email) ?? 'Usuario'
  const { data: profile } = await supabase
    .from('profiles')
    .select('display_name')
    .eq('id', userId)
    .maybeSingle()

  if (!profile?.display_name || profile.display_name === seededName) {
    return '/onboarding/profile'
  }

  const { data: memberships } = await supabase
    .from('group_members')
    .select('group_id')
    .eq('user_id', userId)
    .eq('active', true)

  if (!memberships || memberships.length === 0) return '/onboarding/grupo'
  if (memberships.length === 1) return `/g/${memberships[0].group_id}/hoy`
  return '/'
}

function nullableEmailPrefix(email: string | null | undefined): string | undefined {
  if (!email) return undefined
  const prefix = email.split('@')[0]
  return prefix || undefined
}
