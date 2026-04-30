import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getGroup, InviteShareButton } from '@/features/groups'
import { listGroupMembers, MembersList } from '@/features/members'

export default async function MiembrosPage({
  params,
}: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, members] = await Promise.all([
    getGroup(gid),
    listGroupMembers(gid),
  ])
  if (!group) notFound()

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <h1 className="text-xl font-bold">Miembros</h1>
      <InviteShareButton groupName={group.name} inviteCode={group.invite_code} />
      <p className="text-sm text-muted-foreground px-1">
        {members.length} {members.length === 1 ? 'miembro' : 'miembros'}
      </p>
      <MembersList members={members} />
    </div>
  )
}
