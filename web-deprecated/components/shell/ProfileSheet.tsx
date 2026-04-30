'use client'

import {
  Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle, SheetTrigger,
} from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Separator } from '@/components/ui/separator'
import { User, LogOut, Mail, Phone } from 'lucide-react'
import { signOut } from '@/features/profile'

function initials(name: string): string {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((p) => p.charAt(0).toUpperCase())
    .join('') || '?'
}

export default function ProfileSheet({
  displayName, email, phone,
}: {
  displayName: string
  email: string | null
  phone: string | null
}) {
  return (
    <Sheet>
      <SheetTrigger asChild>
        <Button variant="ghost" size="icon" aria-label="Mi perfil">
          <User className="size-5" />
        </Button>
      </SheetTrigger>
      <SheetContent side="right" className="w-[320px] flex flex-col">
        <SheetHeader className="space-y-3 text-center items-center">
          <Avatar className="size-16">
            <AvatarFallback className="text-lg">{initials(displayName)}</AvatarFallback>
          </Avatar>
          <div className="space-y-1">
            <SheetTitle>{displayName}</SheetTitle>
            <SheetDescription>Tu perfil personal</SheetDescription>
          </div>
        </SheetHeader>

        <Separator />

        <div className="px-4 space-y-3 text-sm">
          {email && (
            <div className="flex items-center gap-3">
              <Mail className="size-4 text-muted-foreground shrink-0" />
              <span className="truncate">{email}</span>
            </div>
          )}
          {phone && (
            <div className="flex items-center gap-3">
              <Phone className="size-4 text-muted-foreground shrink-0" />
              <span>{phone}</span>
            </div>
          )}
          {!email && !phone && (
            <p className="text-muted-foreground text-xs">Sin contacto registrado.</p>
          )}
        </div>

        <div className="mt-auto px-4 pb-4">
          <form action={signOut}>
            <Button variant="outline" className="w-full" type="submit">
              <LogOut className="size-4 mr-2" />
              Cerrar sesión
            </Button>
          </form>
        </div>
      </SheetContent>
    </Sheet>
  )
}
