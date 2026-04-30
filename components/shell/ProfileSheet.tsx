'use client'

import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger } from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { User, LogOut } from 'lucide-react'
import { signOut } from '@/features/profile'

export default function ProfileSheet({ displayName }: { displayName: string }) {
  return (
    <Sheet>
      <SheetTrigger asChild>
        <Button variant="ghost" size="icon" aria-label="Mi perfil">
          <User className="size-5" />
        </Button>
      </SheetTrigger>
      <SheetContent side="right" className="w-[300px]">
        <SheetHeader>
          <SheetTitle>{displayName}</SheetTitle>
        </SheetHeader>
        <div className="mt-6 px-4">
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
