'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import {
  RequestOtpSchema,
  VerifyOtpSchema,
  MagicLinkSchema,
  UpdateProfileSchema,
} from './schemas'

export type ActionResult<T = unknown> =
  | { ok: true; data?: T }
  | { error: { _form?: string[]; [field: string]: string[] | undefined } }

export async function requestOtp(_: unknown, formData: FormData): Promise<ActionResult> {
  const parsed = RequestOtpSchema.safeParse({ phone: formData.get('phone') })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithOtp({
    phone: parsed.data.phone,
    options: { channel: 'sms' },
  })
  if (error) return { error: { _form: [error.message] } }
  return { ok: true }
}

export async function verifyOtp(_: unknown, formData: FormData): Promise<ActionResult> {
  const parsed = VerifyOtpSchema.safeParse({
    phone: formData.get('phone'),
    token: formData.get('token'),
  })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const supabase = await createClient()
  const { error } = await supabase.auth.verifyOtp({
    phone: parsed.data.phone,
    token: parsed.data.token,
    type: 'sms',
  })
  if (error) return { error: { _form: [error.message] } }
  redirect('/onboarding')
}

export async function sendMagicLink(_: unknown, formData: FormData): Promise<ActionResult> {
  const parsed = MagicLinkSchema.safeParse({ email: formData.get('email') })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data.email,
    options: { emailRedirectTo: `${process.env.NEXT_PUBLIC_SITE_URL ?? ''}/auth/callback` },
  })
  if (error) return { error: { _form: [error.message] } }
  return { ok: true }
}

export async function updateProfile(_: unknown, formData: FormData): Promise<ActionResult> {
  const parsed = UpdateProfileSchema.safeParse({ display_name: formData.get('display_name') })
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { error } = await supabase
    .from('profiles')
    .upsert({ id: user.id, display_name: parsed.data.display_name }, { onConflict: 'id' })
  if (error) return { error: { _form: [error.message] } }
  revalidatePath('/')
  redirect('/onboarding/grupo')
}

export async function signOut() {
  const supabase = await createClient()
  await supabase.auth.signOut()
  redirect('/login')
}
