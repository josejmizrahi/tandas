export function formatEventDate(iso: string, timezone: string): string {
  const d = new Date(iso)
  return new Intl.DateTimeFormat('es-MX', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: timezone,
  }).format(d)
}

export function isPastEvent(iso: string): boolean {
  return new Date(iso).getTime() < Date.now()
}

export function isToday(iso: string, timezone: string): boolean {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: timezone }).format(new Date())
  const event = new Intl.DateTimeFormat('en-CA', { timeZone: timezone }).format(new Date(iso))
  return today === event
}

export function isUpcoming(iso: string, days = 14): boolean {
  const ms = new Date(iso).getTime() - Date.now()
  return ms > 0 && ms < days * 86_400_000
}
