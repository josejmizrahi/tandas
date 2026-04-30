import { z } from 'zod'

export const PhoneSchema = z.string().regex(/^\+\d{10,15}$/, 'Formato +52... requerido')

export const RequestOtpSchema = z.object({
  phone: PhoneSchema,
})
export type RequestOtp = z.infer<typeof RequestOtpSchema>

export const VerifyOtpSchema = z.object({
  phone: PhoneSchema,
  token: z.string().regex(/^\d{6}$/, 'Código de 6 dígitos'),
})
export type VerifyOtp = z.infer<typeof VerifyOtpSchema>

export const MagicLinkSchema = z.object({
  email: z.string().email('Email inválido'),
})
export type MagicLink = z.infer<typeof MagicLinkSchema>

export const UpdateProfileSchema = z.object({
  display_name: z.string().min(1, 'Necesario').max(50, 'Máximo 50'),
})
export type UpdateProfile = z.infer<typeof UpdateProfileSchema>
