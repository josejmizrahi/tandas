import 'server-only'
import { createServerClient, type CookieOptions } from '@supabase/ssr'
import { cookies } from 'next/headers'
import type { Database } from '@/lib/db/types'

export async function createClient() {
  const cookieStore = await cookies()
  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (toSet: { name: string; value: string; options: CookieOptions }[]) => {
          try {
            toSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options))
          } catch {
            // Server components can't set cookies; ignore
          }
        },
      },
    }
  )
}
