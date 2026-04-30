import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { getEvent, listAttendance, isAdminOfGroup, EventDetail } from '@/features/events'

export default async function EventDetailPage({
  params,
}: { params: Promise<{ gid: string; eid: string }> }) {
  const { gid, eid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, event, attendance, isAdmin] = await Promise.all([
    getGroup(gid),
    getEvent(eid),
    listAttendance(eid),
    isAdminOfGroup(gid, user.id),
  ])
  if (!group) notFound()
  if (!event) notFound()
  if (event.group_id !== gid) notFound()

  const myAttendance = attendance.find((a) => a.user_id === user.id)

  return (
    <EventDetail
      groupId={gid}
      timezone={group.timezone ?? 'America/Mexico_City'}
      isAdmin={isAdmin}
      currentUserId={user.id}
      event={event}
      attendance={attendance}
      myAttendance={myAttendance}
    />
  )
}
