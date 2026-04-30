import Link from 'next/link'
import { redirect, notFound } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { ArrowLeft } from 'lucide-react'
import { createClient } from '@/lib/supabase/server'
import { getGroupForSettings, GroupSettingsForm } from '@/features/groups'
import { isAdminOfGroup } from '@/features/events'

export default async function GroupSettingsPage({
  params,
}: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, isAdmin] = await Promise.all([
    getGroupForSettings(gid),
    isAdminOfGroup(gid, user.id),
  ])
  if (!group) notFound()
  if (!isAdmin) {
    return (
      <div className="p-4 max-w-md mx-auto">
        <p className="text-sm text-muted-foreground text-center py-8">
          Solo los admins del grupo pueden editar settings.
        </p>
      </div>
    )
  }

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <Link
        href={`/g/${gid}/mas`}
        className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
      >
        <ArrowLeft className="size-3.5" /> Volver a Más
      </Link>
      <Card>
        <CardHeader className="space-y-2">
          <CardTitle>Settings del grupo</CardTitle>
          <CardDescription>
            Cambios afectan eventos y multas a partir de hoy. Las multas viejas conservan la regla con la que se generaron.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <GroupSettingsForm group={group} />
        </CardContent>
      </Card>
    </div>
  )
}
