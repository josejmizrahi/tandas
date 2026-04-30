'use client'

import { useActionState, useEffect, useRef, useState } from 'react'
import { Users, Loader2, Mail, ArrowLeft } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
  FieldSeparator,
} from '@/components/ui/field'
import {
  InputOTP, InputOTPGroup, InputOTPSeparator, InputOTPSlot,
} from '@/components/ui/input-otp'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { requestOtp, verifyOtp, sendMagicLink, type ActionResult } from '../actions'

const RESEND_COOLDOWN_SECONDS = 30

export default function LoginForm() {
  const [phoneValue, setPhoneValue] = useState('')
  const [emailValue, setEmailValue] = useState('')
  const [wantsToEditPhone, setWantsToEditPhone] = useState(true)
  const [otpDigits, setOtpDigits] = useState('')
  const [resendIn, setResendIn] = useState(0)
  const verifyFormRef = useRef<HTMLFormElement>(null)

  const [otpReqState, otpReqAction, otpReqPending] =
    useActionState<ActionResult | null, FormData>(requestOtp, null)
  const [otpVerifyState, otpVerifyAction, otpVerifyPending] =
    useActionState<ActionResult | null, FormData>(verifyOtp, null)
  const [magicState, magicAction, magicPending] =
    useActionState<ActionResult | null, FormData>(sendMagicLink, null)

  const otpRequestSucceeded = otpReqState !== null && 'ok' in otpReqState && otpReqState.ok
  const showVerifyForm = otpRequestSucceeded && !wantsToEditPhone
  const magicLinkSent = magicState !== null && 'ok' in magicState && magicState.ok

  useEffect(() => {
    if (resendIn <= 0) return
    const t = setTimeout(() => setResendIn((n) => Math.max(0, n - 1)), 1000)
    return () => clearTimeout(t)
  }, [resendIn])

  // Auto-submit OTP form when 6 digits are present
  useEffect(() => {
    if (otpDigits.length === 6 && !otpVerifyPending) {
      verifyFormRef.current?.requestSubmit()
    }
  }, [otpDigits, otpVerifyPending])

  function handleResendOtp() {
    if (resendIn > 0) return
    setResendIn(RESEND_COOLDOWN_SECONDS)
    const fd = new FormData()
    fd.set('phone', phoneValue)
    otpReqAction(fd)
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col items-center gap-2 text-center">
        <div className="flex size-12 items-center justify-center rounded-xl bg-primary/10 text-primary">
          <Users className="size-6" />
        </div>
        <h1 className="text-xl font-bold">Tandas</h1>
        <FieldDescription>
          Reglas, multas y splitwise para tu grupo de amigos.
        </FieldDescription>
      </div>

      <Tabs defaultValue="phone" className="w-full">
        <TabsList className="grid grid-cols-2 w-full">
          <TabsTrigger value="phone">Teléfono</TabsTrigger>
          <TabsTrigger value="email">Email</TabsTrigger>
        </TabsList>

        <TabsContent value="phone" className="mt-4">
          {!showVerifyForm ? (
            <form
              action={otpReqAction}
              onSubmit={() => {
                setWantsToEditPhone(false)
                setResendIn(RESEND_COOLDOWN_SECONDS)
              }}
            >
              <FieldGroup>
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
                    value={phoneValue}
                    onChange={(e) => setPhoneValue(e.target.value)}
                  />
                  <FieldDescription>
                    Te mandaremos un código de 6 dígitos por SMS.
                  </FieldDescription>
                  {otpReqState && 'error' in otpReqState && (
                    <FieldDescription className="text-destructive">
                      {otpReqState.error._form?.[0] ?? otpReqState.error.phone?.[0]}
                    </FieldDescription>
                  )}
                </Field>
                <Field>
                  <Button type="submit" disabled={otpReqPending} size="lg">
                    {otpReqPending && <Loader2 className="size-4 animate-spin mr-2" />}
                    {otpReqPending ? 'Enviando…' : 'Enviarme código'}
                  </Button>
                </Field>
              </FieldGroup>
            </form>
          ) : (
            <div>
              <button
                type="button"
                onClick={() => { setWantsToEditPhone(true); setOtpDigits('') }}
                className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors mb-4"
              >
                <ArrowLeft className="size-3.5" />
                Cambiar número
              </button>

              <form action={otpVerifyAction} ref={verifyFormRef}>
                <input type="hidden" name="phone" value={phoneValue} />
                <input type="hidden" name="token" value={otpDigits} />
                <FieldGroup>
                  <FieldDescription className="text-center">
                    Código enviado a <strong>{phoneValue}</strong>
                  </FieldDescription>
                  <Field className="items-center">
                    <FieldLabel htmlFor="otp" className="sr-only">Código de 6 dígitos</FieldLabel>
                    <InputOTP
                      id="otp"
                      maxLength={6}
                      value={otpDigits}
                      onChange={setOtpDigits}
                      autoFocus
                      disabled={otpVerifyPending}
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
                    {otpVerifyState && 'error' in otpVerifyState && (
                      <FieldDescription className="text-destructive text-center">
                        {otpVerifyState.error._form?.[0] ?? otpVerifyState.error.token?.[0]}
                      </FieldDescription>
                    )}
                  </Field>
                  <Field>
                    <Button
                      type="submit"
                      disabled={otpVerifyPending || otpDigits.length < 6}
                      size="lg"
                    >
                      {otpVerifyPending && <Loader2 className="size-4 animate-spin mr-2" />}
                      {otpVerifyPending ? 'Verificando…' : 'Entrar'}
                    </Button>
                  </Field>
                  <button
                    type="button"
                    onClick={handleResendOtp}
                    disabled={resendIn > 0 || otpReqPending}
                    className="text-sm text-muted-foreground underline w-full disabled:no-underline disabled:opacity-50"
                  >
                    {resendIn > 0
                      ? `Reenviar código en ${resendIn}s`
                      : otpReqPending
                      ? 'Enviando…'
                      : 'Reenviar código'}
                  </button>
                </FieldGroup>
              </form>
            </div>
          )}
        </TabsContent>

        <TabsContent value="email" className="mt-4">
          {!magicLinkSent ? (
            <form action={magicAction}>
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="email">Tu email</FieldLabel>
                  <Input
                    id="email"
                    name="email"
                    type="email"
                    placeholder="tu@email.com"
                    autoComplete="email"
                    required
                    value={emailValue}
                    onChange={(e) => setEmailValue(e.target.value)}
                  />
                  <FieldDescription>
                    Te mandaremos un link de acceso. Solo tienes que abrir el correo.
                  </FieldDescription>
                  {magicState && 'error' in magicState && (
                    <FieldDescription className="text-destructive">
                      {magicState.error._form?.[0] ?? magicState.error.email?.[0]}
                    </FieldDescription>
                  )}
                </Field>
                <Field>
                  <Button type="submit" disabled={magicPending} size="lg">
                    {magicPending && <Loader2 className="size-4 animate-spin mr-2" />}
                    {magicPending ? 'Enviando…' : 'Enviarme link'}
                  </Button>
                </Field>
              </FieldGroup>
            </form>
          ) : (
            <div className="flex flex-col items-center gap-3 py-4 text-center">
              <div className="flex size-12 items-center justify-center rounded-full bg-emerald-100 text-emerald-700">
                <Mail className="size-5" />
              </div>
              <div className="space-y-1">
                <p className="font-medium">Revisa tu correo</p>
                <p className="text-sm text-muted-foreground">
                  Te mandamos un link a <strong>{emailValue}</strong>.<br />
                  Ábrelo desde este mismo dispositivo.
                </p>
              </div>
              <button
                type="button"
                onClick={() => {
                  const fd = new FormData()
                  fd.set('email', emailValue)
                  magicAction(fd)
                }}
                disabled={magicPending}
                className="text-sm text-muted-foreground underline disabled:opacity-50"
              >
                {magicPending ? 'Enviando…' : 'Reenviar link'}
              </button>
            </div>
          )}
        </TabsContent>
      </Tabs>

      <FieldSeparator />

      <FieldDescription className="text-center text-xs">
        Al continuar, aceptas las reglas que tu grupo defina y la lógica de multas que voten juntos.
      </FieldDescription>
    </div>
  )
}
