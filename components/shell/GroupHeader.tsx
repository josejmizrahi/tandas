'use client'

import { ChevronDown } from 'lucide-react'

export default function GroupHeader({
  groupName, children,
}: { groupName: string; children: React.ReactNode }) {
  return (
    <header className="sticky top-0 z-30 bg-background/80 backdrop-blur border-b">
      <div className="flex items-center justify-between px-4 h-14">
        <button className="flex items-center gap-2 font-semibold" type="button">
          <span className="size-7 rounded-full bg-primary/15 grid place-items-center text-xs">
            {groupName.charAt(0).toUpperCase()}
          </span>
          <span className="truncate max-w-[180px]">{groupName}</span>
          <ChevronDown className="size-4 opacity-60" />
        </button>
        <div className="flex items-center gap-2">{children}</div>
      </div>
    </header>
  )
}
