import GroupHeader from './GroupHeader'
import ProfileSheet from './ProfileSheet'
import BottomNav from './BottomNav'

export default function AppShell({
  groupId, groupName, displayName, email, phone, children,
}: {
  groupId: string
  groupName: string
  displayName: string
  email: string | null
  phone: string | null
  children: React.ReactNode
}) {
  return (
    <div className="min-h-dvh flex flex-col">
      <GroupHeader groupName={groupName}>
        <ProfileSheet displayName={displayName} email={email} phone={phone} />
      </GroupHeader>
      <main className="flex-1 pb-24">{children}</main>
      <BottomNav groupId={groupId} />
    </div>
  )
}
