import { LoginForm } from '@/features/profile'
import { AlertCircle } from 'lucide-react'

const ERROR_MESSAGES: Record<string, string> = {
  callback_failed: 'No pudimos completar tu inicio de sesión. Intenta de nuevo.',
  missing_code:    'Tu link no traía el código de verificación. Intenta de nuevo.',
  exchange_failed: 'Tu link expiró o ya se usó. Pide uno nuevo.',
  access_denied:   'Acceso denegado.',
  otp_expired:     'Tu código expiró. Pide uno nuevo.',
}

export default async function LoginPage({
  searchParams,
}: { searchParams: Promise<{ error?: string; description?: string }> }) {
  const sp = await searchParams
  const errorMsg = sp.error
    ? ERROR_MESSAGES[sp.error] ?? sp.description ?? 'Algo no salió bien. Intenta de nuevo.'
    : null

  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted/30 p-6 md:p-10">
      <div className="w-full max-w-sm space-y-4">
        {errorMsg && (
          <div className="flex items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
            <AlertCircle className="size-4 mt-0.5 shrink-0" />
            <p>{errorMsg}</p>
          </div>
        )}
        <LoginForm />
      </div>
    </div>
  )
}
