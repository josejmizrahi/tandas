'use client'

import { useActionState, useEffect, useRef, useState } from 'react'
import { Users, Loader2, Phone, ArrowLeft, Mail } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Field, FieldDescription, FieldGroup, FieldLabel, FieldSeparator,
} from '@/components/ui/field'
import {
  InputOTP, InputOTPGroup, InputOTPSeparator, InputOTPSlot,
} from '@/components/ui/input-otp'
import {
  requestOtp, verifyOtp, sendMagicLink, verifyEmailOtp, type ActionResult,
} from '../actions'

const RESEND_COOLDOWN_SECONDS = 30
type Mode = 'pick' | 'email-input' | 'email-verify' | 'phone-input' | 'phone-verify'

export default function LoginForm() {
  const [mode, setMode] = useState<Mode>('pick')

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col items-center gap-2 text-center">
        <button
          type="button"
          onClick={() => setMode('pick')}
          className="flex flex-col items-center gap-2 font-medium"
        >
          <div className="flex size-9 items-center justify-center rounded-md bg-primary text-primary-foreground">
            <Users className="size-5" />
          </div>
          <span className="sr-only">Tandas</span>
        </button>
        <h1 className="text-xl font-bold">Bienvenido a Tandas</h1>
        <FieldDescription>
          Si es tu primera vez, te creamos cuenta automáticamente.
        </FieldDescription>
      </div>

      {mode === 'pick' && (
        <PickMode
          onPickEmail={() => setMode('email-input')}
          onPickPhone={() => setMode('phone-input')}
        />
      )}
      {mode === 'email-input' && (
        <EmailInput onSent={() => setMode('email-verify')} onBack={() => setMode('pick')} />
      )}
      {mode === 'email-verify' && (
        <EmailVerify onBack={() => setMode('email-input')} />
      )}
      {mode === 'phone-input' && (
        <PhoneInput onSent={() => setMode('phone-verify')} onBack={() => setMode('pick')} />
      )}
      {mode === 'phone-verify' && (
        <PhoneVerify onBack={() => setMode('phone-input')} />
      )}

      <FieldDescription className="text-center text-xs">
        Al continuar, aceptas las reglas que tu grupo defina.
      </FieldDescription>
    </div>
  )
}

// ============================================================
function PickMode({
  onPickEmail, onPickPhone,
}: { onPickEmail: () => void; onPickPhone: () => void }) {
  return (
    <FieldGroup>
      <Field>
        <Button onClick={onPickEmail} size="lg">
          <Mail className="size-4 mr-2" />
          Continuar con email
        </Button>
      </Field>
      <FieldSeparator>O</FieldSeparator>
      <Field>
        <Button onClick={onPickPhone} variant="outline" size="lg">
          <Phone className="size-4 mr-2" />
          Continuar con teléfono
        </Button>
      </Field>
    </FieldGroup>
  )
}

// ============================================================
function EmailInput({ onSent, onBack }: { onSent: () => void; onBack: () => void }) {
  const [emailValue, setEmailValue] = useState('')
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(sendMagicLink, null)

  useEffect(() => {
    if (state && 'ok' in state && state.ok) {
      sessionStorage.setItem('tandas:lastEmail', emailValue)
      onSent()
    }
  }, [state, emailValue, onSent])

  return (
    <form action={action}>
      <FieldGroup>
        <BackLink onClick={onBack}>Otro método</BackLink>
        <Field>
          <FieldLabel htmlFor="email">Tu email</FieldLabel>
          <Input
            id="email"
            name="email"
            type="email"
            placeholder="tu@email.com"
            autoComplete="email"
            required
            autoFocus
            value={emailValue}
            onChange={(e) => setEmailValue(e.target.value)}
          />
          <FieldDescription>
            Te mandaremos un código de 6 dígitos por correo.
          </FieldDescription>
          {state && 'error' in state && (
            <FieldDescription className="text-destructive">
              {state.error._form?.[0] ?? state.error.email?.[0]}
            </FieldDescription>
          )}
        </Field>
        <Field>
          <Button type="submit" disabled={pending} size="lg">
            {pending && <Loader2 className="size-4 animate-spin mr-2" />}
            {pending ? 'Enviando…' : 'Enviarme código'}
          </Button>
        </Field>
      </FieldGroup>
    </form>
  )
}

// ============================================================
function EmailVerify({ onBack }: { onBack: () => void }) {
  const [emailValue] = useState(() =>
    typeof window !== 'undefined' ? sessionStorage.getItem('tandas:lastEmail') ?? '' : ''
  )
  const [otpDigits, setOtpDigits] = useState('')
  const [resendIn, setResendIn] = useState(RESEND_COOLDOWN_SECONDS)
  const verifyFormRef = useRef<HTMLFormElement>(null)

  const [verifyState, verifyAction, verifyPending] =
    useActionState<ActionResult | null, FormData>(verifyEmailOtp, null)
  const [reqState, reqAction, reqPending] =
    useActionState<ActionResult | null, FormData>(sendMagicLink, null)

  useEffect(() => {
    if (resendIn <= 0) return
    const t = setTimeout(() => setResendIn((n) => Math.max(0, n - 1)), 1000)
    return () => clearTimeout(t)
  }, [resendIn])

  useEffect(() => {
    if (otpDigits.length === 6 && !verifyPending) {
      verifyFormRef.current?.requestSubmit()
    }
  }, [otpDigits, verifyPending])

  function handleResend() {
    if (resendIn > 0) return
    setResendIn(RESEND_COOLDOWN_SECONDS)
    const fd = new FormData()
    fd.set('email', emailValue)
    reqAction(fd)
  }

  return (
    <form action={verifyAction} ref={verifyFormRef}>
      <input type="hidden" name="email" value={emailValue} />
      <input type="hidden" name="token" value={otpDigits} />
      <FieldGroup>
        <BackLink onClick={onBack}>Cambiar email</BackLink>
        <FieldDescription className="text-center">
          Código enviado a <strong>{emailValue}</strong>.<br />
          Busca el correo y copia el código de 6 dígitos.
        </FieldDescription>
        <Field className="items-center">
          <FieldLabel htmlFor="email-otp" className="sr-only">Código</FieldLabel>
          <InputOTP
            id="email-otp"
            maxLength={6}
            value={otpDigits}
            onChange={setOtpDigits}
            autoFocus
            disabled={verifyPending}
          >
            <InputOTPGroup>
              <InputOTPSlot index={0} />
              <InputOTPSlot index={1} />
              <InputOTPSlot index={2} />
            </InputOTPGroup>
            <InputOTPSeparator />
            <InputOTPGroup>
              <InputOTPSlot index={3} />
              <InputOTPSlot index={4} />
              <InputOTPSlot index={5} />
            </InputOTPGroup>
          </InputOTP>
          {verifyState && 'error' in verifyState && (
            <FieldDescription className="text-destructive text-center">
              {verifyState.error._form?.[0] ?? verifyState.error.token?.[0]}
            </FieldDescription>
          )}
          {reqState && 'ok' in reqState && reqState.ok && (
            <FieldDescription className="text-emerald-600 text-center">
              Código reenviado.
            </FieldDescription>
          )}
        </Field>
        <Field>
          <Button type="submit" disabled={verifyPending || otpDigits.length < 6} size="lg">
            {verifyPending && <Loader2 className="size-4 animate-spin mr-2" />}
            {verifyPending ? 'Verificando…' : 'Entrar'}
          </Button>
        </Field>
        <ResendButton resendIn={resendIn} pending={reqPending} onClick={handleResend} />
      </FieldGroup>
    </form>
  )
}

// ============================================================
function PhoneInput({ onSent, onBack }: { onSent: () => void; onBack: () => void }) {
  const [phoneValue, setPhoneValue] = useState('')
  const [state, action, pending] =
    useActionState<ActionResult | null, FormData>(requestOtp, null)

  useEffect(() => {
    if (state && 'ok' in state && state.ok) {
      sessionStorage.setItem('tandas:lastPhone', phoneValue)
      onSent()
    }
  }, [state, phoneValue, onSent])

  return (
    <form action={action}>
      <FieldGroup>
        <BackLink onClick={onBack}>Otro método</BackLink>
        <Field>
          <FieldLabel htmlFor="phone">Tu número</FieldLabel>
          <Input
            id="phone"
            name="phone"
            type="tel"
            placeholder="+5215555551234"
            inputMode="tel"
            autoComplete="tel"
            required
            autoFocus
            value={phoneValue}
            onChange={(e) => setPhoneValue(e.target.value)}
          />
          <FieldDescription>
            Te mandaremos un código de 6 dígitos por SMS.
          </FieldDescription>
          {state && 'error' in state && (
            <FieldDescription className="text-destructive">
              {state.error._form?.[0] ?? state.error.phone?.[0]}
            </FieldDescription>
          )}
        </Field>
        <Field>
          <Button type="submit" disabled={pending} size="lg">
            {pending && <Loader2 className="size-4 animate-spin mr-2" />}
            {pending ? 'Enviando…' : 'Enviarme código'}
          </Button>
        </Field>
      </FieldGroup>
    </form>
  )
}

// ============================================================
function PhoneVerify({ onBack }: { onBack: () => void }) {
  const [phoneValue] = useState(() =>
    typeof window !== 'undefined' ? sessionStorage.getItem('tandas:lastPhone') ?? '' : ''
  )
  const [otpDigits, setOtpDigits] = useState('')
  const [resendIn, setResendIn] = useState(RESEND_COOLDOWN_SECONDS)
  const verifyFormRef = useRef<HTMLFormElement>(null)

  const [verifyState, verifyAction, verifyPending] =
    useActionState<ActionResult | null, FormData>(verifyOtp, null)
  const [reqState, reqAction, reqPending] =
    useActionState<ActionResult | null, FormData>(requestOtp, null)

  useEffect(() => {
    if (resendIn <= 0) return
    const t = setTimeout(() => setResendIn((n) => Math.max(0, n - 1)), 1000)
    return () => clearTimeout(t)
  }, [resendIn])

  useEffect(() => {
    if (otpDigits.length === 6 && !verifyPending) {
      verifyFormRef.current?.requestSubmit()
    }
  }, [otpDigits, verifyPending])

  function handleResend() {
    if (resendIn > 0) return
    setResendIn(RESEND_COOLDOWN_SECONDS)
    const fd = new FormData()
    fd.set('phone', phoneValue)
    reqAction(fd)
  }

  return (
    <form action={verifyAction} ref={verifyFormRef}>
      <input type="hidden" name="phone" value={phoneValue} />
      <input type="hidden" name="token" value={otpDigits} />
      <FieldGroup>
        <BackLink onClick={onBack}>Cambiar número</BackLink>
        <FieldDescription className="text-center">
          Código enviado a <strong>{phoneValue}</strong>
        </FieldDescription>
        <Field className="items-center">
          <FieldLabel htmlFor="phone-otp" className="sr-only">Código</FieldLabel>
          <InputOTP
            id="phone-otp"
            maxLength={6}
            value={otpDigits}
            onChange={setOtpDigits}
            autoFocus
            disabled={verifyPending}
          >
            <InputOTPGroup>
              <InputOTPSlot index={0} />
              <InputOTPSlot index={1} />
              <InputOTPSlot index={2} />
            </InputOTPGroup>
            <InputOTPSeparator />
            <InputOTPGroup>
              <InputOTPSlot index={3} />
              <InputOTPSlot index={4} />
              <InputOTPSlot index={5} />
            </InputOTPGroup>
          </InputOTP>
          {verifyState && 'error' in verifyState && (
            <FieldDescription className="text-destructive text-center">
              {verifyState.error._form?.[0] ?? verifyState.error.token?.[0]}
            </FieldDescription>
          )}
          {reqState && 'ok' in reqState && reqState.ok && (
            <FieldDescription className="text-emerald-600 text-center">
              Código reenviado.
            </FieldDescription>
          )}
        </Field>
        <Field>
          <Button type="submit" disabled={verifyPending || otpDigits.length < 6} size="lg">
            {verifyPending && <Loader2 className="size-4 animate-spin mr-2" />}
            {verifyPending ? 'Verificando…' : 'Entrar'}
          </Button>
        </Field>
        <ResendButton resendIn={resendIn} pending={reqPending} onClick={handleResend} />
      </FieldGroup>
    </form>
  )
}

// ============================================================
function BackLink({ children, onClick }: { children: React.ReactNode; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors -mb-2"
    >
      <ArrowLeft className="size-3.5" />
      {children}
    </button>
  )
}

function ResendButton({
  resendIn, pending, onClick,
}: { resendIn: number; pending: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={resendIn > 0 || pending}
      className="text-sm text-muted-foreground underline w-full disabled:no-underline disabled:opacity-50"
    >
      {resendIn > 0
        ? `Reenviar código en ${resendIn}s`
        : pending
        ? 'Enviando…'
        : 'Reenviar código'}
    </button>
  )
}
