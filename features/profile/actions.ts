'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { headers } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import {
  RequestOtpSchema,
  VerifyOtpSchema,
  MagicLinkSchema,
  UpdateProfileSchema,
} from './schemas'

/**
 * Resolve the public origin for OAuth/magic-link redirect URLs.
 * Order: NEXT_PUBLIC_SITE_URL env → x-forwarded-host header (Vercel) →
 * host header → empty (will fail Supabase validation, surfacing a real error).
 */
async function resolveOrigin(): Promise<string> {
  const env = process.env.NEXT_PUBLIC_SITE_URL?.trim()
  if (env) return env.replace(/\/$/, '')

  const h = await headers()
  const forwardedHost = h.get('x-forwarded-host')
  const forwardedProto = h.get('x-forwarded-proto') ?? 'https'
  if (forwardedHost) return `${forwardedProto}://${forwardedHost}`

  const host = h.get('host')
  if (host) {
    const proto = host.startsWith('localhost') ? 'http' : 'https'
    return `${proto}://${host}`
  }
  return ''
}

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
  const origin = await resolveOrigin()
  if (!origin) {
    return { error: { _form: ['No se pudo determinar el dominio del sitio. Configura NEXT_PUBLIC_SITE_URL.'] } }
  }
  const emailRedirectTo = `${origin}/auth/callback`
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data.email,
    options: { emailRedirectTo },
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
