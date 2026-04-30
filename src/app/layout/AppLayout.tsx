import { Outlet, Link } from 'react-router-dom'
import { LogOut, Users } from 'lucide-react'
import { useAuth } from '@/app/providers/AuthProvider'
import { Button } from '@/components/ui/button'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { initials } from '@/lib/utils'

export function AppLayout() {
  const { user, signOut } = useAuth()
  const name =
    (user?.user_metadata as { display_name?: string } | undefined)?.display_name ||
    user?.email ||
    'Yo'

  return (
    <div className="min-h-screen bg-background">
      <header className="sticky top-0 z-30 border-b bg-background/80 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-5xl items-center justify-between px-4">
          <Link to="/grupos" className="flex items-center gap-2 font-semibold">
            <Users className="h-5 w-5" />
            Tandas
          </Link>
          <div className="flex items-center gap-3">
            <div className="hidden text-sm text-muted-foreground sm:block">{name}</div>
            <Avatar className="h-8 w-8">
              <AvatarFallback>{initials(name)}</AvatarFallback>
            </Avatar>
            <Button variant="ghost" size="icon" onClick={signOut} title="Cerrar sesión">
              <LogOut className="h-4 w-4" />
            </Button>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-5xl px-4 py-6">
        <Outlet />
      </main>
    </div>
  )
}
