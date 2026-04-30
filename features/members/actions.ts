'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { JoinByCodeSchema } from './schemas'

export type ActionResult = { ok: true } | { error: { _form?: string[]; [k: string]: string[] | undefined } }

export async function joinByCode(_: unknown, formData: FormData): Promise<ActionResult> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const parsed = JoinByCodeSchema.safeParse({ code: formData.get('code') })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const { data, error } = await supabase.rpc('join_group_by_code', { p_code: parsed.data.code })
  if (error) return { error: { _form: [error.message] } }

  revalidatePath('/')
  redirect(`/g/${(data as { id: string }).id}`)
}
