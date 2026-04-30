'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Home, Calendar, Scale, Wallet, MoreHorizontal } from 'lucide-react'
import { cn } from '@/lib/utils'

type Tab = { href: string; label: string; Icon: typeof Home }

export default function BottomNav({ groupId }: { groupId: string }) {
  const pathname = usePathname()
  const tabs: Tab[] = [
    { href: `/g/${groupId}/hoy`,     label: 'Hoy',      Icon: Home },
    { href: `/g/${groupId}/eventos`, label: 'Eventos',  Icon: Calendar },
    { href: `/g/${groupId}/reglas`,  label: 'Reglas',   Icon: Scale },
    { href: `/g/${groupId}/plata`,   label: 'Plata',    Icon: Wallet },
    { href: `/g/${groupId}/mas`,     label: 'Más',      Icon: MoreHorizontal },
  ]

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-30 glass-chrome border-t border-white/10 pb-[env(safe-area-inset-bottom)]">
      <ul className="flex items-stretch justify-around h-16 max-w-md mx-auto">
        {tabs.map(({ href, label, Icon }) => {
          const active = pathname === href || pathname.startsWith(href + '/')
          return (
            <li key={href} className="flex-1">
              <Link
                href={href}
                className={cn(
                  'flex flex-col items-center justify-center gap-0.5 h-full text-xs transition-colors',
                  active ? 'text-foreground' : 'text-muted-foreground hover:text-foreground'
                )}
              >
                <Icon
                  className={cn('size-5', active && 'text-primary')}
                  strokeWidth={active ? 2.25 : 2}
                />
                <span className={cn(active && 'font-medium')}>{label}</span>
              </Link>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}
