import { Users } from 'lucide-react'

export default function OnboardingLayout({ children }: { children: React.ReactNode }) {
  return (
    <main className="min-h-svh flex flex-col items-center justify-center bg-muted/30 p-6">
      <div className="w-full max-w-sm flex flex-col items-center gap-6">
        <div className="flex flex-col items-center gap-2 text-center">
          <div className="flex size-12 items-center justify-center rounded-xl bg-primary/10 text-primary">
            <Users className="size-6" />
          </div>
          <h1 className="text-xl font-bold">Tandas</h1>
        </div>
        {children}
      </div>
    </main>
  )
}
