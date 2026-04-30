'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { toast } from 'sonner'
import { requestOtp, verifyOtp, sendMagicLink, type ActionResult } from '../actions'

export default function LoginForm() {
  const [phoneValue, setPhoneValue] = useState('')
  // True when user explicitly wants to edit the phone number again
  // (clicked "Cambiar número"). Drives whether to show the request form
  // or the OTP entry form, in conjunction with otpReqState.
  const [wantsToEditPhone, setWantsToEditPhone] = useState(true)

  const [otpReqState, otpReqAction, otpReqPending] =
    useActionState<ActionResult | null, FormData>(requestOtp, null)
  const [otpVerifyState, otpVerifyAction, otpVerifyPending] =
    useActionState<ActionResult | null, FormData>(verifyOtp, null)
  const [magicState, magicAction, magicPending] =
    useActionState<ActionResult | null, FormData>(sendMagicLink, null)

  const otpRequestSucceeded = otpReqState !== null && 'ok' in otpReqState && otpReqState.ok
  const showVerifyForm = otpRequestSucceeded && !wantsToEditPhone
  const magicLinkSent = magicState !== null && 'ok' in magicState && magicState.ok

  return (
    <Tabs defaultValue="phone" className="w-full">
      <TabsList className="grid grid-cols-2 w-full">
        <TabsTrigger value="phone">Teléfono</TabsTrigger>
        <TabsTrigger value="email">Email</TabsTrigger>
      </TabsList>

      <TabsContent value="phone" className="space-y-4 mt-4">
        {!showVerifyForm ? (
          <form
            action={otpReqAction}
            onSubmit={() => setWantsToEditPhone(false)}
            className="space-y-3"
          >
            <div className="space-y-2">
              <Label htmlFor="phone">Tu número</Label>
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
              {otpReqState && 'error' in otpReqState && (
                <p className="text-destructive text-sm">
                  {otpReqState.error._form?.[0] ?? otpReqState.error.phone?.[0]}
                </p>
              )}
            </div>
            <Button type="submit" disabled={otpReqPending} className="w-full">
              {otpReqPending ? 'Enviando…' : 'Enviarme código'}
            </Button>
          </form>
        ) : (
          <form action={otpVerifyAction} className="space-y-3">
            <input type="hidden" name="phone" value={phoneValue} />
            <p className="text-sm text-muted-foreground">
              Te mandamos un código por SMS a <strong>{phoneValue}</strong>.
            </p>
            <div className="space-y-2">
              <Label htmlFor="token">Código de 6 dígitos</Label>
              <Input
                id="token"
                name="token"
                type="text"
                inputMode="numeric"
                pattern="\d{6}"
                autoComplete="one-time-code"
                required
              />
              {otpVerifyState && 'error' in otpVerifyState && (
                <p className="text-destructive text-sm">
                  {otpVerifyState.error._form?.[0] ?? otpVerifyState.error.token?.[0]}
                </p>
              )}
            </div>
            <Button type="submit" disabled={otpVerifyPending} className="w-full">
              {otpVerifyPending ? 'Verificando…' : 'Entrar'}
            </Button>
            <button
              type="button"
              className="text-sm text-muted-foreground underline w-full"
              onClick={() => setWantsToEditPhone(true)}
            >
              Cambiar número
            </button>
          </form>
        )}
      </TabsContent>

      <TabsContent value="email" className="space-y-4 mt-4">
        <form
          action={magicAction}
          onSubmit={() => {
            // Show toast optimistically; if action errors, the inline message replaces it
            toast.message('Enviando link…')
          }}
          className="space-y-3"
        >
          <div className="space-y-2">
            <Label htmlFor="email">Tu email</Label>
            <Input
              id="email"
              name="email"
              type="email"
              placeholder="tu@email.com"
              autoComplete="email"
              required
            />
            {magicState && 'error' in magicState && (
              <p className="text-destructive text-sm">
                {magicState.error._form?.[0] ?? magicState.error.email?.[0]}
              </p>
            )}
            {magicLinkSent && (
              <p className="text-emerald-600 text-sm">
                Revisa tu correo, te mandamos el link de acceso.
              </p>
            )}
          </div>
          <Button type="submit" disabled={magicPending} className="w-full">
            {magicPending ? 'Enviando…' : 'Enviarme link'}
          </Button>
        </form>
      </TabsContent>
    </Tabs>
  )
}
