import { redirect } from 'next/navigation'

export default async function GroupRootRedirect({
  params,
}: { params: Promise<{ gid: string }> }) {
  const { gid } = await params
  redirect(`/g/${gid}/hoy`)
}
