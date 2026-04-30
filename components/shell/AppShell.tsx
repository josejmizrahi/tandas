import GroupHeader from './GroupHeader'
import ProfileSheet from './ProfileSheet'

export default function AppShell({
  groupName, displayName, children,
}: { groupName: string; displayName: string; children: React.ReactNode }) {
  return (
    <div className="min-h-dvh flex flex-col">
      <GroupHeader groupName={groupName}>
        <ProfileSheet displayName={displayName} />
      </GroupHeader>
      <main className="flex-1 pb-20">{children}</main>
      {/* BottomNav arrives in Phase 2 */}
    </div>
  )
}
