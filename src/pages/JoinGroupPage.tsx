import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

export function JoinGroupPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [code, setCode] = useState('')

  const join = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('join_group_by_code', { p_code: code.trim() })
      if (error) throw error
      return data
    },
    onSuccess: (group) => {
      qc.invalidateQueries({ queryKey: ['groups'] })
      toast.success(`Te uniste a ${group.name}`)
      navigate(`/grupos/${group.id}`)
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!code.trim()) return
    join.mutate()
  }

  return (
    <div className="mx-auto max-w-md space-y-4">
      <Button variant="ghost" size="sm" onClick={() => navigate('/grupos')}>
        <ArrowLeft className="h-4 w-4" /> Volver
      </Button>
      <Card>
        <CardHeader>
          <CardTitle>Unirme a un grupo</CardTitle>
          <CardDescription>Pídele el código de invitación al admin del grupo.</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={onSubmit} className="space-y-4">
            <div className="space-y-1.5">
              <Label>Código</Label>
              <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="ej: a3f9d7c1" required />
            </div>
            <Button type="submit" className="w-full" disabled={join.isPending}>
              {join.isPending ? 'Validando…' : 'Unirme'}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
