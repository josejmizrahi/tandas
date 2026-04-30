import { redirect, notFound } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { createClient } from '@/lib/supabase/server'
import { getGroup } from '@/features/groups'
import { ProposeRuleForm } from '@/features/rules'

export default async function ProponerReglaPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')
  const group = await getGroup(gid)
  if (!group) notFound()

  return (
    <div className="p-4 space-y-4 max-w-md mx-auto">
      <Card>
        <CardHeader className="space-y-2">
          <CardTitle>Proponer regla</CardTitle>
          <CardDescription>
            Elige un preset o ajústalo. Al guardar se abre una votación; si pasa quórum + umbral, la regla se activa sola.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ProposeRuleForm groupId={gid} />
        </CardContent>
      </Card>
    </div>
  )
}
