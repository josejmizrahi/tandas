import Link from 'next/link'
import { Card, CardContent } from '@/components/ui/card'
import { Users, ChevronRight } from 'lucide-react'

export default async function MasPage({ params }: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  return (
    <div className="p-4 max-w-md mx-auto space-y-4">
      <h1 className="text-xl font-bold">Más</h1>
      <Card>
        <CardContent className="p-0">
          <ul className="divide-y">
            <li>
              <Link
                href={`/g/${gid}/mas/miembros`}
                className="flex items-center gap-3 p-4 hover:bg-accent/50 transition-colors"
              >
                <Users className="size-5 text-muted-foreground" />
                <span className="flex-1">Miembros del grupo</span>
                <ChevronRight className="size-4 text-muted-foreground" />
              </Link>
            </li>
          </ul>
        </CardContent>
      </Card>
      <p className="text-xs text-muted-foreground text-center">
        Settings, fondo común y switcher de grupos llegan en próximas fases.
      </p>
    </div>
  )
}
