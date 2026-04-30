import { cn } from '@/lib/utils'

export default function StepIndicator({
  total, current,
}: { total: number; current: number }) {
  return (
    <div className="flex items-center gap-1.5" aria-label={`Paso ${current} de ${total}`}>
      {Array.from({ length: total }).map((_, i) => (
        <div
          key={i}
          className={cn(
            'h-1.5 rounded-full transition-all',
            i < current ? 'bg-primary' : 'bg-border',
            i === current - 1 ? 'w-8' : 'w-2',
          )}
        />
      ))}
    </div>
  )
}
