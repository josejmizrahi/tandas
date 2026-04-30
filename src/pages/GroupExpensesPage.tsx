import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, Plus, Receipt } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useGroup, useGroupId, useGroupMembers } from '@/hooks/useGroupContext'
import { useAuth } from '@/app/providers/AuthProvider'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { EmptyState } from '@/components/ui/empty-state'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { formatCurrency, formatDate } from '@/lib/utils'

export function GroupExpensesPage() {
  const groupId = useGroupId()
  const navigate = useNavigate()
  const { data: group } = useGroup(groupId)
  const { data: members } = useGroupMembers(groupId)

  const balances = useQuery({
    queryKey: ['balances', groupId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('group_balances')
        .select('*')
        .eq('group_id', groupId)
      if (error) throw error
      return data as Array<{ group_id: string; user_id: string; balance: number }>
    },
  })

  const expenses = useQuery({
    queryKey: ['expenses', groupId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('expenses')
        .select('*, shares:expense_shares(*)')
        .eq('group_id', groupId)
        .order('expense_date', { ascending: false })
      if (error) throw error
      return (data ?? []) as unknown as Array<{
        id: string
        description: string
        amount: number
        expense_date: string
        paid_by: string
        notes: string | null
        shares: Array<{ user_id: string; amount: number }>
      }>
    },
  })

  const memberName = (uid: string) =>
    members?.find((m) => m.user_id === uid)?.profile?.display_name ?? '—'

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <Button variant="ghost" size="sm" onClick={() => navigate(`/grupos/${groupId}`)} className="-ml-3">
          <ArrowLeft className="h-4 w-4" /> Volver
        </Button>
        <NewExpenseDialog groupId={groupId} />
      </div>
      <div>
        <h1 className="text-2xl font-semibold">Gastos compartidos</h1>
        <p className="text-sm text-muted-foreground">Splitwise interno + multas + pots todo en un balance neto.</p>
      </div>

      <Card>
        <CardHeader><CardTitle className="text-base">Balances</CardTitle></CardHeader>
        <CardContent className="space-y-1.5 text-sm">
          {balances.data?.length === 0 && <div className="text-muted-foreground">Sin movimientos.</div>}
          {balances.data?.map((b) => {
            const v = Number(b.balance ?? 0)
            return (
              <div key={b.user_id} className="flex justify-between border-b py-1.5 last:border-0">
                <span>{memberName(b.user_id!)}</span>
                <span className={v > 0 ? 'text-emerald-600 dark:text-emerald-400' : v < 0 ? 'text-rose-600 dark:text-rose-400' : ''}>
                  {v > 0 ? 'le deben ' : v < 0 ? 'debe ' : ''}{formatCurrency(Math.abs(v), group?.currency ?? 'MXN')}
                </span>
              </div>
            )
          })}
        </CardContent>
      </Card>

      {expenses.isLoading ? (
        <div className="text-sm text-muted-foreground">Cargando…</div>
      ) : !expenses.data?.length ? (
        <EmptyState icon={<Receipt className="h-8 w-8" />} title="Sin gastos" description="Agrega un gasto y elige cómo dividirlo." />
      ) : (
        <div className="space-y-2">
          {expenses.data.map((e) => (
            <Card key={e.id}>
              <CardHeader className="flex-row items-start justify-between space-y-0">
                <div>
                  <CardTitle className="text-base">{e.description}</CardTitle>
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    {formatDate(e.expense_date)} · {memberName(e.paid_by)} pagó · {e.shares.length} divisiones
                  </div>
                </div>
                <span className="text-lg font-semibold">{formatCurrency(Number(e.amount), group?.currency ?? 'MXN')}</span>
              </CardHeader>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}

function NewExpenseDialog({ groupId }: { groupId: string }) {
  const qc = useQueryClient()
  const { user } = useAuth()
  const { data: members } = useGroupMembers(groupId)
  const [open, setOpen] = useState(false)
  const [form, setForm] = useState({ description: '', amount: '', notes: '' })
  const [included, setIncluded] = useState<string[]>([])

  const create = useMutation({
    mutationFn: async () => {
      const amount = Number(form.amount)
      const peopleIds = included.length > 0 ? included : members!.map((m) => m.user_id)
      const each = +(amount / peopleIds.length).toFixed(2)
      // adjust last share to absorb rounding
      const shares = peopleIds.map((uid, i) => ({
        user_id: uid,
        amount: i === peopleIds.length - 1 ? +(amount - each * (peopleIds.length - 1)).toFixed(2) : each,
      }))
      const { error } = await supabase.rpc('create_expense_with_shares', {
        p_group_id: groupId,
        p_description: form.description,
        p_amount: amount,
        p_expense_date: null,
        p_split_type: 'equal',
        p_notes: form.notes || null,
        p_event_id: null,
        p_shares: shares,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['expenses', groupId] })
      qc.invalidateQueries({ queryKey: ['balances', groupId] })
      setOpen(false)
      setIncluded([])
      setForm({ description: '', amount: '', notes: '' })
      toast.success('Gasto registrado')
    },
    onError: (e: Error) => toast.error(e.message),
  })

  function onSubmit(e: FormEvent) { e.preventDefault(); create.mutate() }

  // default include everyone
  const allIds = members?.map((m) => m.user_id) ?? []
  const allIncluded = included.length === 0

  return (
    <Dialog open={open} onOpenChange={(o) => { setOpen(o); if (o && user) setIncluded([]) }}>
      <DialogTrigger asChild>
        <Button><Plus className="h-4 w-4" /> Nuevo gasto</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader><DialogTitle>Nuevo gasto</DialogTitle></DialogHeader>
        <form onSubmit={onSubmit} className="space-y-3">
          <div className="space-y-1.5">
            <Label>Descripción</Label>
            <Input value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} placeholder="Comida del martes" required />
          </div>
          <div className="space-y-1.5">
            <Label>Monto total</Label>
            <Input type="number" min="0.01" step="0.01" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} required />
          </div>
          <div className="space-y-1.5">
            <Label>Dividir entre (clic para incluir/excluir)</Label>
            <div className="flex flex-wrap gap-2">
              {members?.map((m) => {
                const isIn = allIncluded || included.includes(m.user_id)
                return (
                  <button
                    key={m.user_id}
                    type="button"
                    onClick={() => {
                      if (allIncluded) {
                        setIncluded(allIds.filter((id) => id !== m.user_id))
                      } else if (isIn) {
                        setIncluded(included.filter((id) => id !== m.user_id))
                      } else {
                        setIncluded([...included, m.user_id])
                      }
                    }}
                    className={`rounded-full border px-3 py-1 text-xs ${isIn ? 'bg-primary text-primary-foreground' : 'bg-background'}`}
                  >
                    {m.profile?.display_name ?? 'miembro'}
                  </button>
                )
              })}
            </div>
            <div className="text-xs text-muted-foreground">{allIncluded ? 'Todos incluidos · división equitativa' : `${included.length} incluidos`}</div>
          </div>
          <div className="space-y-1.5">
            <Label>Notas</Label>
            <Textarea value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
          </div>
          <DialogFooter>
            <Button type="submit" disabled={create.isPending}>{create.isPending ? 'Guardando…' : 'Guardar'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
