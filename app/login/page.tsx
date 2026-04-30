import { LoginForm } from '@/features/profile'

export default function LoginPage() {
  return (
    <main className="min-h-dvh flex flex-col items-center justify-center p-6 gap-8">
      <div className="text-center space-y-2">
        <h1 className="text-3xl font-bold">Tandas</h1>
        <p className="text-muted-foreground">Reglas, multas y splitwise para tu grupo.</p>
      </div>
      <LoginForm />
    </main>
  )
}
