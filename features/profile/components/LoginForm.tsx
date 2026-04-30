'use client'

import { useActionState, useState } from 'react'
import { Users } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
  FieldSeparator,
} from '@/components/ui/field'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { toast } from 'sonner'
import { requestOtp, verifyOtp, sendMagicLink, type ActionResult } from '../actions'

export default function LoginForm() {
  const [phoneValue, setPhoneValue] = useState('')
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
    <div className="flex flex-col gap-6">
      {/* Brand block — centered icon + heading + tagline */}
      <div className="flex flex-col items-center gap-2 text-center">
        <div className="flex size-10 items-center justify-center rounded-md bg-primary/10 text-primary">
          <Users className="size-5" />
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
              onSubmit={() => setWantsToEditPhone(false)}
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
                  {otpReqState && 'error' in otpReqState && (
                    <FieldDescription className="text-destructive">
                      {otpReqState.error._form?.[0] ?? otpReqState.error.phone?.[0]}
                    </FieldDescription>
                  )}
                </Field>
                <Field>
                  <Button type="submit" disabled={otpReqPending}>
                    {otpReqPending ? 'Enviando…' : 'Enviarme código'}
                  </Button>
                </Field>
              </FieldGroup>
            </form>
          ) : (
            <form action={otpVerifyAction}>
              <input type="hidden" name="phone" value={phoneValue} />
              <FieldGroup>
                <FieldDescription className="text-center">
                  Te mandamos un código por SMS a <strong>{phoneValue}</strong>.
                </FieldDescription>
                <Field>
                  <FieldLabel htmlFor="token">Código de 6 dígitos</FieldLabel>
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
                    <FieldDescription className="text-destructive">
                      {otpVerifyState.error._form?.[0] ?? otpVerifyState.error.token?.[0]}
                    </FieldDescription>
                  )}
                </Field>
                <Field>
                  <Button type="submit" disabled={otpVerifyPending}>
                    {otpVerifyPending ? 'Verificando…' : 'Entrar'}
                  </Button>
                </Field>
                <button
                  type="button"
                  className="text-sm text-muted-foreground underline w-full"
                  onClick={() => setWantsToEditPhone(true)}
                >
                  Cambiar número
                </button>
              </FieldGroup>
            </form>
          )}
        </TabsContent>

        <TabsContent value="email" className="mt-4">
          <form
            action={magicAction}
            onSubmit={() => toast.message('Enviando link…')}
          >
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
                />
                {magicState && 'error' in magicState && (
                  <FieldDescription className="text-destructive">
                    {magicState.error._form?.[0] ?? magicState.error.email?.[0]}
                  </FieldDescription>
                )}
                {magicLinkSent && (
                  <FieldDescription className="text-emerald-600">
                    Revisa tu correo, te mandamos el link de acceso.
                  </FieldDescription>
                )}
              </Field>
              <Field>
                <Button type="submit" disabled={magicPending}>
                  {magicPending ? 'Enviando…' : 'Enviarme link'}
                </Button>
              </Field>
            </FieldGroup>
          </form>
        </TabsContent>
      </Tabs>

      <FieldSeparator />

      <FieldDescription className="text-center text-xs">
        Al continuar, aceptas las reglas que tu grupo defina y la lógica de multas que voten juntos.
      </FieldDescription>
    </div>
  )
}
