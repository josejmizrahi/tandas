import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { listGroupMembers } from '@/features/members'
import { isAdminOfGroup } from '@/features/events'
import {
  listMyFines, listGroupFines, FinesList, IssueFineSheet,
} from '@/features/fines'
import { RequestAmnestyDialog } from '@/features/votes'

export default async function PlataPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, myFines, groupFines, isAdmin, members] = await Promise.all([
    getGroup(gid),
    listMyFines(gid, user.id),
    listGroupFines(gid),
    isAdminOfGroup(gid, user.id),
    listGroupMembers(gid),
  ])
  if (!group) notFound()

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <div className="flex items-center justify-between gap-2">
        <h1 className="text-xl font-bold">Multas</h1>
        {isAdmin && (
          <div className="flex items-center gap-2">
            <RequestAmnestyDialog groupId={gid} />
            <IssueFineSheet
              groupId={gid}
              members={members.map((m) => ({
                user_id: m.user_id,
                display_name: m.profiles?.display_name ?? null,
              }))}
            />
          </div>
        )}
      </div>
      <FinesList groupId={gid} myFines={myFines} groupFines={groupFines} />
    </div>
  )
}
