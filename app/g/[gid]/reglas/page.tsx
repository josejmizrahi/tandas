import { redirect, notFound } from 'next/navigation'
import Link from 'next/link'
import { Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { listActiveRules, listProposedRules, listArchivedRules, RulesList } from '@/features/rules'

export default async function ReglasPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [group, active, proposed, archived] = await Promise.all([
    getGroup(gid),
    listActiveRules(gid),
    listProposedRules(gid),
    listArchivedRules(gid),
  ])
  if (!group) notFound()

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <div className="flex items-center justify-between gap-2">
        <h1 className="text-xl font-bold">Reglas</h1>
        <Button asChild size="sm">
          <Link href={`/g/${gid}/reglas/proponer`}>
            <Plus className="size-4 mr-1" />
            Proponer
          </Link>
        </Button>
      </div>
      <RulesList groupId={gid} active={active} proposed={proposed} archived={archived} />
    </div>
  )
}
