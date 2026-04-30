import { NextResponse, type NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'

export async function GET(request: NextRequest) {
  const url = new URL(request.url)
  const code = url.searchParams.get('code')
  const errorParam = url.searchParams.get('error')
  const errorCode = url.searchParams.get('error_code')
  const errorDescription = url.searchParams.get('error_description')
  const next = url.searchParams.get('next') ?? '/'

  // Compute the absolute base for the redirect — use the forwarded host on
  // Vercel, otherwise fall back to the request URL. Important: previously we
  // built `new URL(next, request.url)` which can pick up the wrong protocol
  // behind a proxy.
  const forwardedHost = request.headers.get('x-forwarded-host')
  const forwardedProto = request.headers.get('x-forwarded-proto') ?? 'https'
  const baseUrl = forwardedHost
    ? `${forwardedProto}://${forwardedHost}`
    : url.origin

  // Supabase returned an error in the verification step (expired link, etc).
  if (errorParam || errorCode) {
    const params = new URLSearchParams({
      error: errorCode ?? errorParam ?? 'callback_failed',
      ...(errorDescription ? { description: errorDescription } : {}),
    })
    return NextResponse.redirect(`${baseUrl}/login?${params.toString()}`)
  }

  if (!code) {
    return NextResponse.redirect(`${baseUrl}/login?error=missing_code`)
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.exchangeCodeForSession(code)
  if (error) {
    const params = new URLSearchParams({
      error: 'exchange_failed',
      description: error.message,
    })
    return NextResponse.redirect(`${baseUrl}/login?${params.toString()}`)
  }

  return NextResponse.redirect(`${baseUrl}${next.startsWith('/') ? next : '/' + next}`)
}
