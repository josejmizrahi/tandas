'use client'

import { Button } from '@/components/ui/button'
import { Share2 } from 'lucide-react'
import { toast } from 'sonner'

export default function InviteShareButton({
  groupName, inviteCode,
}: { groupName: string; inviteCode: string }) {
  async function handleClick() {
    const origin = typeof window !== 'undefined' ? window.location.origin : ''
    const message = `Te invito a "${groupName}" en Tandas. Código: ${inviteCode}\n${origin}/g/join`

    if (typeof navigator !== 'undefined' && 'share' in navigator) {
      try {
        await navigator.share({ title: `Únete a ${groupName}`, text: message })
        return
      } catch {
        // user cancelled or unsupported, fall through to wa.me
      }
    }
    const waUrl = `https://wa.me/?text=${encodeURIComponent(message)}`
    window.open(waUrl, '_blank', 'noopener')
  }

  async function copyCode() {
    await navigator.clipboard.writeText(inviteCode)
    toast.success('Código copiado')
  }

  return (
    <div className="flex gap-2">
      <Button onClick={handleClick} className="flex-1">
        <Share2 className="size-4 mr-2" />
        Invitar amigos
      </Button>
      <Button variant="outline" onClick={copyCode}>
        {inviteCode}
      </Button>
    </div>
  )
}
