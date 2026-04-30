import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { LoginForm } from '@/features/profile'

export default function LoginPage() {
  return (
    <main className="min-h-dvh flex flex-col items-center justify-center p-6 bg-muted/30">
      <Card className="w-full max-w-sm">
        <CardHeader className="text-center space-y-2">
          <CardTitle className="text-2xl">Tandas</CardTitle>
          <CardDescription>Reglas, multas y splitwise para tu grupo.</CardDescription>
        </CardHeader>
        <CardContent>
          <LoginForm />
        </CardContent>
      </Card>
    </main>
  )
}
