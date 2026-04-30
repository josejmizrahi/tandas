import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import AppShell from '@/components/shell/AppShell'

export default async function GroupLayout({
  children, params,
}: { children: React.ReactNode; params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [{ data: group }, { data: profile }] = await Promise.all([
    supabase.from('groups').select('id, name').eq('id', gid).maybeSingle(),
    supabase.from('profiles').select('display_name').eq('id', user.id).maybeSingle(),
  ])
  if (!group) notFound()

  return (
    <AppShell groupName={group.name} displayName={profile?.display_name ?? 'Tú'}>
      {children}
    </AppShell>
  )
}
