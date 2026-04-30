import { redirect, notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { getGroup } from '@/features/groups'
import {
  listUpcomingEvents, listPastEvents, EventCard, NewEventSheet, isAdminOfGroup,
} from '@/features/events'

export default async function EventosPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, upcoming, past, isAdmin] = await Promise.all([
    getGroup(gid),
    listUpcomingEvents(gid),
    listPastEvents(gid),
    isAdminOfGroup(gid, user.id),
  ])
  if (!group) notFound()

  const tz = group.timezone ?? 'America/Mexico_City'

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <h1 className="text-xl font-bold">Eventos</h1>

      {isAdmin && <NewEventSheet groupId={gid} />}

      <Tabs defaultValue="upcoming">
        <TabsList className="grid grid-cols-2 w-full">
          <TabsTrigger value="upcoming">Próximos ({upcoming.length})</TabsTrigger>
          <TabsTrigger value="past">Histórico ({past.length})</TabsTrigger>
        </TabsList>
        <TabsContent value="upcoming" className="space-y-2 mt-4">
          {upcoming.map((e) => <EventCard key={e.id} groupId={gid} event={e} timezone={tz} />)}
          {upcoming.length === 0 && (
            <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground">
              No hay eventos próximos.
            </div>
          )}
        </TabsContent>
        <TabsContent value="past" className="space-y-2 mt-4">
          {past.map((e) => <EventCard key={e.id} groupId={gid} event={e} timezone={tz} />)}
          {past.length === 0 && (
            <div className="rounded-lg border p-8 text-center text-sm text-muted-foreground">
              Aún no hay eventos pasados.
            </div>
          )}
        </TabsContent>
      </Tabs>
    </div>
  )
}
