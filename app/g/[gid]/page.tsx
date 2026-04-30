import { notFound } from 'next/navigation'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { getGroup, InviteShareButton } from '@/features/groups'
import { listGroupMembers, MembersList } from '@/features/members'

export default async function GroupHomePage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const [group, members] = await Promise.all([getGroup(gid), listGroupMembers(gid)])
  if (!group) notFound()

  return (
    <div className="p-4 space-y-6 max-w-md mx-auto">
      <Card>
        <CardHeader>
          <CardTitle>{group.name}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <InviteShareButton groupName={group.name} inviteCode={group.invite_code} />
          <p className="text-sm text-muted-foreground">
            {members.length} {members.length === 1 ? 'miembro' : 'miembros'}
          </p>
        </CardContent>
      </Card>

      <section className="space-y-2">
        <h2 className="text-sm font-medium text-muted-foreground px-1">Miembros</h2>
        <MembersList members={members} />
      </section>

      <p className="text-center text-xs text-muted-foreground">
        Más funciones llegan en Fase 2 (eventos, multas, gastos).
      </p>
    </div>
  )
}
