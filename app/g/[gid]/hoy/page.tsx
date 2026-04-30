import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { getNextEventForGroup, getMyAttendance, NextEventCard } from '@/features/events'

export default async function HoyPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const group = await getGroup(gid)
  if (!group) notFound()

  const event = await getNextEventForGroup(gid)
  const myAttendance = event ? await getMyAttendance(event.id, user.id) : null

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <h1 className="text-xl font-bold">Hoy</h1>
      <NextEventCard
        groupId={gid}
        timezone={group.timezone ?? 'America/Mexico_City'}
        event={event}
        myRsvp={(myAttendance?.rsvp_status as 'pending' | 'going' | 'maybe' | 'declined' | undefined) ?? null}
      />
    </div>
  )
}
