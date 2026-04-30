import { createBrowserRouter, Navigate, Outlet } from 'react-router-dom'
import { useAuth } from '@/app/providers/AuthProvider'
import { AppLayout } from '@/app/layout/AppLayout'
import { LoginPage } from '@/pages/LoginPage'
import { GroupsListPage } from '@/pages/GroupsListPage'
import { JoinGroupPage } from '@/pages/JoinGroupPage'
import { NewGroupPage } from '@/pages/NewGroupPage'
import { GroupOverviewPage } from '@/pages/GroupOverviewPage'
import { GroupRulesPage } from '@/pages/GroupRulesPage'
import { GroupTandasPage } from '@/pages/GroupTandasPage'
import { GroupFinesPage } from '@/pages/GroupFinesPage'
import { GroupExpensesPage } from '@/pages/GroupExpensesPage'
import { GroupMembersPage } from '@/pages/GroupMembersPage'
import { GroupPotsPage } from '@/pages/GroupPotsPage'
import { GroupVotesPage } from '@/pages/GroupVotesPage'

function ProtectedRoute() {
  const { session, loading } = useAuth()
  if (loading) {
    return (
      <div className="flex h-screen items-center justify-center text-sm text-muted-foreground">
        Cargando…
      </div>
    )
  }
  if (!session) return <Navigate to="/login" replace />
  return <Outlet />
}

export const router = createBrowserRouter([
  { path: '/login', element: <LoginPage /> },
  {
    element: <ProtectedRoute />,
    children: [
      {
        element: <AppLayout />,
        children: [
          { index: true, element: <Navigate to="/grupos" replace /> },
          { path: 'grupos', element: <GroupsListPage /> },
          { path: 'grupos/nuevo', element: <NewGroupPage /> },
          { path: 'grupos/unirse', element: <JoinGroupPage /> },
          { path: 'grupos/:groupId', element: <GroupOverviewPage /> },
          { path: 'grupos/:groupId/miembros', element: <GroupMembersPage /> },
          { path: 'grupos/:groupId/reglas', element: <GroupRulesPage /> },
          { path: 'grupos/:groupId/tandas', element: <GroupTandasPage /> },
          { path: 'grupos/:groupId/multas', element: <GroupFinesPage /> },
          { path: 'grupos/:groupId/pots', element: <GroupPotsPage /> },
          { path: 'grupos/:groupId/gastos', element: <GroupExpensesPage /> },
          { path: 'grupos/:groupId/votaciones', element: <GroupVotesPage /> },
        ],
      },
    ],
  },
  { path: '*', element: <Navigate to="/" replace /> },
])
