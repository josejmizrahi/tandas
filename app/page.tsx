import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'

export default async function HomePage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: profile } = await supabase
    .from('profiles')
    .select('display_name')
    .eq('id', user.id)
    .maybeSingle()

  const seededName = nullableEmailPrefix(user.email) ?? 'Usuario'
  if (!profile?.display_name || profile.display_name === seededName) {
    redirect('/onboarding')
  }

  const { data: memberships } = await supabase
    .from('group_members')
    .select('group_id, groups(id, name)')
    .eq('user_id', user.id)
    .eq('active', true)

  if (!memberships || memberships.length === 0) redirect('/g/new')
  if (memberships.length === 1) redirect(`/g/${memberships[0].group_id}`)

  return (
    <main className="min-h-dvh p-6 max-w-md mx-auto space-y-4">
      <h1 className="text-xl font-bold">Tus grupos</h1>
      <ul className="space-y-2">
        {memberships.map((m) => (
          <li key={m.group_id}>
            <Link className="block p-4 rounded-lg border hover:bg-accent" href={`/g/${m.group_id}`}>
              {m.groups?.name ?? 'Grupo'}
            </Link>
          </li>
        ))}
      </ul>
      <div className="grid gap-2">
        <Link className="text-center py-2 underline" href="/g/new">Crear grupo nuevo</Link>
        <Link className="text-center py-2 underline" href="/g/join">Unirme con código</Link>
      </div>
    </main>
  )
}

function nullableEmailPrefix(email: string | undefined): string | undefined {
  if (!email) return undefined
  const prefix = email.split('@')[0]
  return prefix || undefined
}
