# Apple-Native Polish Sprint

Goal: make ruul **feel** like Apple Invites, not by recreating Luma but by
using the Apple frameworks Apple Invites itself uses. No third-party SDKs.

## Status

| # | Feature | Framework | Status |
|---|---|---|---|
| 1 | Inline map preview in detail | MapKit (`Map` view) | ✅ shipped |
| 2 | Countdown line ("EMPIEZA EN 2 DÍAS") | pure logic | ✅ shipped |
| 3 | Animated mesh gradient covers | SwiftUI `MeshGradient` + `TimelineView` | ✅ shipped (4x4, breathing) |
| 4 | Calendar add (EKEvent + .ics) | EventKit | ✅ shipped (00013) |
| 5 | Real-time RSVP | Supabase Realtime | ✅ shipped (00013) |
| 6 | Weather forecast badge | WeatherKit | ⏳ pending |
| 7 | Live Activity / Dynamic Island | ActivityKit | ⏳ pending (needs new target) |
| 8 | Lock screen widget | WidgetKit | ⏳ pending (needs new target) |
| 9 | Rich push notifications | UserNotifications + service ext | ⏳ pending |
| 10 | Apple Music playlist link | MusicKit | ⏳ pending (nice-to-have) |

---

## Pending — items that need new Xcode targets (do these on the Mac)

These cannot be created from the CLI alone — Xcode needs to add the targets
because they require `Info.plist`, signing, and capability wiring that lives
in `project.pbxproj`.

### Live Activity + Dynamic Island (impact: highest)

**Target type:** Widget Extension with `ActivityKit` checked.

**Setup steps in Xcode:**
1. File → New → Target → Widget Extension
2. Name: `EventLiveActivity`
3. Check "Include Live Activity"
4. Add to App Group: `group.com.josejmizrahi.ruul` (so the extension reads
   the same store as the main app)
5. Capabilities: enable `Push Notifications` + `Live Activities` on both the
   main app target and the extension

**What to build inside the extension:**
- `EventActivityAttributes` (Codable) with: `eventId`, `title`, `coverColors`, `startsAt`, `locationName`
- `ContentState` with: `secondsRemaining`, `myStatus`, `seatsTaken`
- Dynamic Island regions:
  - Compact leading: cover color dot
  - Compact trailing: countdown text
  - Expanded: full layout — cover gradient strip + title + countdown + "Cómo llegar" button (deep links to detail)
- Lock screen view: same layout, full width

**Trigger from main app:**
- When user RSVPs `.going` AND event is <2h away → start activity via
  `Activity.request(...)`
- When event ends → call `activity.end()`
- Push updates from Supabase Edge Function for state changes (we already
  have notifications scaffolding)

### Lock Screen Widget (impact: high)

Same Widget Extension target as above.

**What to build:**
- `EventNextWidget` showing user's next event via App Group shared
  UserDefaults written by the main app on every refresh
- Sizes: `.systemSmall` (cover + title + date), `.systemMedium` (cover +
  title + date + location)
- Lock screen widgets (`.accessoryRectangular`, `.accessoryCircular`)

### WeatherKit (impact: medium-high — distinctive Apple feel)

No target needed, but requires:
1. Add WeatherKit capability to main target
2. Add `NSLocationWhenInUseUsageDescription` to Info.plist (or use event coords)
3. Apple Developer portal: enable WeatherKit for the app id

**What to build:**
- `WeatherService` actor that fetches `Weather` for `event.startsAt + locationLat/Lng`
- `EventWeatherBadge` view: "☀️ 22°" or "🌧️ 18°" — only shows when:
  - Event has coords
  - Event is <14 days away (forecast horizon)
  - Event is outdoor (heuristic: location name matches keywords like "parque", "playa", "terraza" — opt-in flag on Event later)
- Place in `titleBlock` next to the dateLine

### Rich Push Notifications (impact: medium)

Needs Notification Service Extension target.

- Attach event cover image as the notification image
- Custom UI for RSVP changes ("3 amigos van a tu evento")

### Apple Music (impact: low — nice-to-have)

- Host attaches a playlist URL to the event when creating
- Detail view shows a "🎵 Playlist del evento" row that opens Music
- Stretch: pull artwork from MusicKit and use it as the cover
