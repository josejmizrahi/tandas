# Tandas iOS Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar Phase 1 de la app nativa iOS de Tandas: auth (SiwA + Phone + Email OTP) + onboarding + crear/joinear grupo (con tipología) + welcome + lista de grupos + group summary placeholder, todo end-to-end contra Supabase real.

**Architecture:** SwiftUI + iOS 26.0 firme + `@Observable` viewmodels + actor-based repos contra `supabase-swift` + RPCs `security definer`. Liquid Glass real (`glassEffect()`) sin fallback. Cero lógica de negocio en Swift — todo via RPCs ya existentes (incluyendo el `00010` que se crea aquí). Mocks por protocol para `#Preview` y snapshots.

**Tech Stack:** Swift 6, SwiftUI 6, iOS 26.0, `supabase-swift` (v2.x), Swift Testing (`@Test`), `swift-snapshot-testing`, XCUITest, xcodegen, GitHub Actions macos-15.

**Spec:** `docs/superpowers/specs/2026-04-30-tandas-ios-phase-1-design.md`

**Notes for the executor:**
- Most Xcode/simulator verification steps require the user's Mac; an agent without GUI access should ask the user to run them and report.
- The Supabase project `fpfvlrwcskhgsjuhrjpz` is live; migration `00010` applies remotely via the Supabase MCP server (`apply_migration`) — confirm with the user before applying.
- `supabase-swift` API references in this plan target v2.x. If the SDK API has shifted, adjust the call sites accordingly while preserving the protocol contracts.
- Sign in with Apple in simulator requires a logged-in iCloud account on the simulator; if testing fails on this, fall back to `MockAuthService` for local UI work and verify SiwA on a real device.

---

## File Structure

```
tandas/
├── ios/
│   ├── project.yml                         ← xcodegen config (Task 1)
│   ├── Makefile                            ← `make project` (Task 1)
│   ├── Tandas.xcodeproj/                   ← gitignored, regenerable
│   └── Tandas/
│       ├── TandasApp.swift                 ← @main (Task 1, finalized Task 8)
│       ├── Resources/
│       │   ├── Info.plist                  ← Task 1
│       │   ├── Tandas.entitlements         ← Task 1 (SiwA only)
│       │   └── Assets.xcassets/            ← Task 1
│       ├── Supabase/
│       │   ├── SupabaseClient.swift        ← Task 3
│       │   ├── AuthService.swift           ← Task 5
│       │   └── Repos/
│       │       ├── ProfileRepository.swift ← Task 6
│       │       └── GroupsRepository.swift  ← Task 7
│       ├── Models/
│       │   ├── Profile.swift               ← Task 4
│       │   ├── Group.swift                 ← Task 4
│       │   ├── GroupType.swift             ← Task 4
│       │   ├── Member.swift                ← Task 4
│       │   └── ViewState.swift             ← Task 4
│       ├── DesignSystem/
│       │   ├── Tokens.swift                ← Task 4
│       │   ├── Typography.swift            ← Task 4
│       │   ├── AdaptiveGlass.swift         ← Task 4
│       │   ├── MeshBackground.swift        ← Task 4
│       │   └── Components/
│       │       ├── GlassCard.swift         ← Task 4
│       │       ├── GlassCapsuleButton.swift← Task 4
│       │       ├── Field.swift             ← Task 4
│       │       ├── OTPInput.swift          ← Task 10
│       │       ├── TypologyCard.swift      ← Task 14
│       │       ├── WalletGroupCard.swift   ← Task 16
│       │       └── WelcomeStepCard.swift   ← Task 15
│       ├── Shell/
│       │   └── AuthGate.swift              ← Task 8
│       └── Features/
│           ├── Auth/
│           │   ├── LoginView.swift         ← Task 9
│           │   ├── OTPInputView.swift      ← Task 10
│           │   ├── OnboardingView.swift    ← Task 11
│           │   └── AuthViewModel.swift     ← Tasks 9–11
│           ├── Groups/
│           │   ├── EmptyGroupsView.swift   ← Task 12
│           │   ├── JoinByCodeView.swift    ← Task 13
│           │   ├── NewGroupWizard.swift    ← Task 14
│           │   ├── WelcomeView.swift       ← Task 15
│           │   ├── GroupsListView.swift    ← Task 16
│           │   ├── GroupSummaryView.swift  ← Task 17
│           │   └── GroupsViewModel.swift   ← Tasks 12–17
│           ├── Events/.gitkeep             ← Task 1
│           ├── Rules/.gitkeep              ← Task 1
│           └── Fines/.gitkeep              ← Task 1
├── ios/TandasTests/                        ← Tasks 5,6,7,9,10,…
├── ios/TandasUITests/                      ← Task 18
├── supabase/migrations/
│   └── 00010_add_group_type_to_create_rpc.sql ← Task 2
├── .github/workflows/
│   └── ios-ci.yml                          ← Task 19
├── .gitignore                              ← updated Task 1
└── (web-deprecated/ ← deleted Task 1)
```

---

## Task 1: Repo cleanup, xcodegen scaffold, empty app builds

**Files:**
- Delete: `web-deprecated/` (entire directory)
- Create: `ios/project.yml`
- Create: `ios/Makefile`
- Create: `ios/Tandas/TandasApp.swift`
- Create: `ios/Tandas/Resources/Info.plist`
- Create: `ios/Tandas/Resources/Tandas.entitlements`
- Create: `ios/Tandas/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `ios/Tandas/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `ios/Tandas/Resources/Assets.xcassets/Contents.json`
- Create: `ios/Tandas/Features/Events/.gitkeep`
- Create: `ios/Tandas/Features/Rules/.gitkeep`
- Create: `ios/Tandas/Features/Fines/.gitkeep`
- Modify: `.gitignore`

- [ ] **Step 1: Confirm prereqs with user (manual)**

Ask the user to confirm:
1. `brew install xcodegen` ran successfully (`xcodegen --version` should print 2.x).
2. Their Apple Developer Team ID (10-char alphanumeric, from `developer.apple.com/account`).

Block until both confirmed.

- [ ] **Step 2: Delete `web-deprecated/`**

```bash
git rm -rf web-deprecated/
```

Expected: hundreds of files deleted, all staged.

- [ ] **Step 3: Update `.gitignore` for iOS artifacts**

Append to existing `.gitignore`:

```
# iOS / Xcode
ios/Tandas.xcodeproj/
ios/.build/
ios/DerivedData/
ios/build/
ios/*.xcworkspace/
.DS_Store
*.xcuserstate
*.xcuserdatad/
```

- [ ] **Step 4: Write `ios/project.yml`**

Replace `<TEAM_ID>` with the user's Apple Developer Team ID confirmed in Step 1.

```yaml
name: Tandas
options:
  bundleIdPrefix: com.josejmizrahi
  deploymentTarget:
    iOS: "26.0"
  developmentLanguage: es
  groupSortPosition: top
  createIntermediateGroups: true
configs:
  Debug: debug
  Release: release
settings:
  base:
    DEVELOPMENT_TEAM: <TEAM_ID>
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: YES
    GENERATE_INFOPLIST_FILE: NO
    INFOPLIST_FILE: Tandas/Resources/Info.plist
    CODE_SIGN_ENTITLEMENTS: Tandas/Resources/Tandas.entitlements
    CODE_SIGN_STYLE: Automatic
    PRODUCT_BUNDLE_IDENTIFIER: com.josejmizrahi.tandas
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
packages:
  Supabase:
    url: https://github.com/supabase/supabase-swift
    from: "2.20.0"
  SnapshotTesting:
    url: https://github.com/pointfreeco/swift-snapshot-testing
    from: "1.17.0"
targets:
  Tandas:
    type: application
    platform: iOS
    sources:
      - path: Tandas
        excludes:
          - "Resources/Info.plist"
          - "Resources/Tandas.entitlements"
    resources:
      - path: Tandas/Resources/Assets.xcassets
    dependencies:
      - package: Supabase
        product: Supabase
    info:
      path: Tandas/Resources/Info.plist
    settings:
      base:
        TARGETED_DEVICE_FAMILY: "1"
        SUPPORTS_MACCATALYST: NO
  TandasTests:
    type: bundle.unit-test
    platform: iOS
    sources: TandasTests
    dependencies:
      - target: Tandas
      - package: SnapshotTesting
        product: SnapshotTesting
    settings:
      base:
        BUNDLE_LOADER: "$(TEST_HOST)"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Tandas.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Tandas"
  TandasUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: TandasUITests
    dependencies:
      - target: Tandas
schemes:
  Tandas:
    build:
      targets:
        Tandas: all
        TandasTests: [test]
        TandasUITests: [test]
    test:
      targets:
        - TandasTests
        - TandasUITests
      gatherCoverageData: true
```

- [ ] **Step 5: Write `ios/Makefile`**

```makefile
.PHONY: project build test clean

project:
	cd $(dir $(realpath $(firstword $(MAKEFILE_LIST)))) && xcodegen

build: project
	xcodebuild build \
		-project ios/Tandas.xcodeproj \
		-scheme Tandas \
		-destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
		| xcpretty

test: project
	xcodebuild test \
		-project ios/Tandas.xcodeproj \
		-scheme Tandas \
		-destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
		| xcpretty

clean:
	rm -rf ios/Tandas.xcodeproj ios/.build ios/DerivedData ios/build
```

- [ ] **Step 6: Create resource files**

`ios/Tandas/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>es</string>
  <key>CFBundleDisplayName</key>
  <string>Tandas</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key>
  <string>$(CURRENT_PROJECT_VERSION)</string>
  <key>LSRequiresIPhoneOS</key>
  <true/>
  <key>UILaunchScreen</key>
  <dict/>
  <key>UIRequiredDeviceCapabilities</key>
  <array>
    <string>arm64</string>
  </array>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
  </array>
  <key>UIUserInterfaceStyle</key>
  <string>Dark</string>
  <key>NSAppleMusicUsageDescription</key>
  <string/>
</dict>
</plist>
```

`ios/Tandas/Resources/Tandas.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.applesignin</key>
  <array>
    <string>Default</string>
  </array>
</dict>
</plist>
```

`ios/Tandas/Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : { "author" : "xcode", "version" : 1 }
}
```

`ios/Tandas/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

`ios/Tandas/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "red" : "0.611", "green" : "0.482", "blue" : "0.957" }
      },
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

- [ ] **Step 7: Write `ios/Tandas/TandasApp.swift` (placeholder)**

```swift
import SwiftUI

@main
struct TandasApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Tandas")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 8: Add `.gitkeep` placeholders for empty feature dirs**

```bash
touch ios/Tandas/Features/Events/.gitkeep \
      ios/Tandas/Features/Rules/.gitkeep \
      ios/Tandas/Features/Fines/.gitkeep
```

- [ ] **Step 9: Generate Xcode project**

Ask user to run:

```bash
cd ios && make project
```

Expected: `xcodegen` prints "✅ Project generated" and `ios/Tandas.xcodeproj/` exists.

- [ ] **Step 10: Build empty app**

Ask user to run:

```bash
cd ios && make build
```

Expected: `BUILD SUCCEEDED`. App installs in simulator showing "Tandas" centered on black.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(ios): xcodegen scaffold + drop web-deprecated

- xcodegen project.yml + Makefile (`make project|build|test|clean`)
- Info.plist (es-MX, dark mode forced)
- Sign in with Apple entitlement only (push/groups deferred)
- Bundle id com.josejmizrahi.tandas, iOS 26.0 deployment
- Empty app shell (TandasApp.swift)
- web-deprecated/ removed (preserved in git history)
EOF
)"
```

---

## Task 2: Migration `00010_add_group_type_to_create_rpc.sql`

**Files:**
- Create: `supabase/migrations/00010_add_group_type_to_create_rpc.sql`

- [ ] **Step 1: Write the migration**

```sql
-- Phase 1 iOS: extend create_group_with_admin to accept group_type.
-- The column was added in 00009 with default 'recurring_dinner', but the RPC
-- was never updated, so creating a group via the iOS app couldn't set the type.

drop function if exists public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean
);

create or replace function public.create_group_with_admin(
  p_name text,
  p_description text,
  p_event_label text,
  p_currency text,
  p_timezone text,
  p_default_day int,
  p_default_time time,
  p_default_location text,
  p_voting_threshold numeric,
  p_voting_quorum numeric,
  p_fund_enabled boolean,
  p_group_type text
)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  insert into public.groups (
    name, description, created_by, event_label, currency, timezone,
    default_day_of_week, default_start_time, default_location,
    voting_threshold, voting_quorum, fund_enabled, group_type
  ) values (
    p_name, p_description, auth.uid(),
    coalesce(p_event_label, 'Tanda'),
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    p_default_day, p_default_time, p_default_location,
    coalesce(p_voting_threshold, 0.5),
    coalesce(p_voting_quorum, 0.5),
    coalesce(p_fund_enabled, true),
    coalesce(p_group_type, 'recurring_dinner')
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, turn_order, on_committee)
  values (g.id, auth.uid(), 'admin', 1, true);
  return g;
end;
$$;

revoke execute on function public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean, text
) from public, anon;

grant execute on function public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean, text
) to authenticated;
```

- [ ] **Step 2: Apply migration to remote Supabase**

Use Supabase MCP `apply_migration` tool against project `fpfvlrwcskhgsjuhrjpz` with the SQL above. Confirm with user before applying.

Expected: migration applied without errors. Verify with:

```sql
select pg_get_function_identity_arguments('public.create_group_with_admin'::regproc);
```

Expected output includes 12 args ending in `, p_group_type text`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/00010_add_group_type_to_create_rpc.sql
git commit -m "feat(db): migration 00010 — create_group_with_admin accepts group_type"
```

---

## Task 3: SupabaseClient singleton

**Files:**
- Create: `ios/Tandas/Supabase/SupabaseClient.swift`
- Modify: `ios/Tandas/TandasApp.swift`
- Create: `.env.example` (in repo root, if not exists; document `TANDAS_SUPABASE_URL` and `TANDAS_SUPABASE_ANON_KEY`)

- [ ] **Step 1: Get Supabase config from user**

Ask user for:
- Supabase URL (`https://fpfvlrwcskhgsjuhrjpz.supabase.co` per CLAUDE.md)
- Supabase anon key (from `developer.supabase.com` dashboard → Project Settings → API)

These go into `Info.plist` build settings via xcconfig (no `.env` for Swift apps; iOS embeds them in the bundle).

- [ ] **Step 2: Update `project.yml` to inject Supabase config**

Edit `ios/project.yml`, add to `targets.Tandas.settings.base`:

```yaml
        TANDAS_SUPABASE_URL: $(inherited)
        TANDAS_SUPABASE_ANON_KEY: $(inherited)
```

And update `Info.plist` to read them:

```xml
  <key>TandasSupabaseURL</key>
  <string>$(TANDAS_SUPABASE_URL)</string>
  <key>TandasSupabaseAnonKey</key>
  <string>$(TANDAS_SUPABASE_ANON_KEY)</string>
```

Then create `ios/Tandas.local.xcconfig` (gitignored) with:

```
TANDAS_SUPABASE_URL = https:/$()/fpfvlrwcskhgsjuhrjpz.supabase.co
TANDAS_SUPABASE_ANON_KEY = <ANON_KEY_FROM_USER>
```

(`$()` escapes the double-slash that xcconfig would otherwise treat as comment.)

Add to `.gitignore`:

```
ios/Tandas.local.xcconfig
```

And reference it in `project.yml` configs:

```yaml
configs:
  Debug:
    type: debug
    xcconfig: Tandas.local.xcconfig
  Release:
    type: release
    xcconfig: Tandas.local.xcconfig
```

- [ ] **Step 3: Write `SupabaseClient.swift`**

```swift
import Foundation
import Supabase

enum SupabaseConfigError: Error {
    case missingURL
    case missingAnonKey
    case malformedURL
}

@MainActor
enum SupabaseEnvironment {
    static let shared: SupabaseClient = {
        do {
            return try makeClient()
        } catch {
            fatalError("Supabase configuration error: \(error)")
        }
    }()

    static func makeClient() throws -> SupabaseClient {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let urlString = info["TandasSupabaseURL"] as? String, !urlString.isEmpty else {
            throw SupabaseConfigError.missingURL
        }
        guard let anonKey = info["TandasSupabaseAnonKey"] as? String, !anonKey.isEmpty else {
            throw SupabaseConfigError.missingAnonKey
        }
        guard let url = URL(string: urlString) else {
            throw SupabaseConfigError.malformedURL
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}
```

- [ ] **Step 4: Update `TandasApp.swift` to inject the client**

```swift
import SwiftUI
import Supabase

@main
struct TandasApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.supabase, SupabaseEnvironment.shared)
        }
    }
}

private struct SupabaseClientKey: EnvironmentKey {
    @MainActor static var defaultValue: SupabaseClient { SupabaseEnvironment.shared }
}

extension EnvironmentValues {
    var supabase: SupabaseClient {
        get { self[SupabaseClientKey.self] }
        set { self[SupabaseClientKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(\.supabase) private var supabase
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Tandas")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Supabase: \(supabase.supabaseURL.host() ?? "?")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
    }
}
```

- [ ] **Step 5: Regenerate project, build, verify**

Ask user to run:

```bash
cd ios && make project && make build
```

Expected: `BUILD SUCCEEDED`. App now shows "Supabase: fpfvlrwcskhgsjuhrjpz.supabase.co" caption.

- [ ] **Step 6: Commit**

```bash
git add ios/project.yml ios/Tandas/Supabase/SupabaseClient.swift \
        ios/Tandas/TandasApp.swift ios/Tandas/Resources/Info.plist .gitignore
git commit -m "feat(ios): SupabaseClient singleton + xcconfig-injected URL/anon key"
```

---

## Task 4: Models, ViewState, and DesignSystem foundation

**Files:**
- Create: `ios/Tandas/Models/Profile.swift`
- Create: `ios/Tandas/Models/Group.swift`
- Create: `ios/Tandas/Models/GroupType.swift`
- Create: `ios/Tandas/Models/Member.swift`
- Create: `ios/Tandas/Models/ViewState.swift`
- Create: `ios/Tandas/DesignSystem/Tokens.swift`
- Create: `ios/Tandas/DesignSystem/Typography.swift`
- Create: `ios/Tandas/DesignSystem/AdaptiveGlass.swift`
- Create: `ios/Tandas/DesignSystem/MeshBackground.swift`
- Create: `ios/Tandas/DesignSystem/Components/GlassCard.swift`
- Create: `ios/Tandas/DesignSystem/Components/GlassCapsuleButton.swift`
- Create: `ios/Tandas/DesignSystem/Components/Field.swift`
- Create: `ios/TandasTests/ModelsTests.swift`

- [ ] **Step 1: Write Codable model tests first**

`ios/TandasTests/ModelsTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("Models")
struct ModelsTests {
    @Test("GroupType decodes snake_case from Supabase")
    func groupTypeSnakeCase() throws {
        let json = #"{"group_type":"recurring_dinner"}"#.data(using: .utf8)!
        struct Wrap: Decodable { let groupType: GroupType }
        let decoder = JSONDecoder.tandas
        let wrap = try decoder.decode(Wrap.self, from: json)
        #expect(wrap.groupType == .recurringDinner)
    }

    @Test("Group decodes from Supabase row")
    func groupDecode() throws {
        let json = """
        {
          "id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "name":"Cena martes",
          "description":null,
          "group_type":"recurring_dinner",
          "invite_code":"abc12345",
          "created_at":"2026-04-30T10:00:00Z"
        }
        """.data(using: .utf8)!
        let g = try JSONDecoder.tandas.decode(Group.self, from: json)
        #expect(g.name == "Cena martes")
        #expect(g.groupType == .recurringDinner)
        #expect(g.inviteCode == "abc12345")
    }

    @Test("Profile.displayName empty means onboarding pending")
    func profileEmptyName() throws {
        let json = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","display_name":""}"#.data(using: .utf8)!
        let p = try JSONDecoder.tandas.decode(Profile.self, from: json)
        #expect(p.displayName.isEmpty)
        #expect(p.needsOnboarding)
    }
}
```

- [ ] **Step 2: Run tests (expected to fail — types don't exist yet)**

Ask user to run:

```bash
cd ios && make test
```

Expected: compilation errors referencing `GroupType`, `Group`, `Profile`, `JSONDecoder.tandas`.

- [ ] **Step 3: Implement `GroupType.swift`**

```swift
import Foundation

enum GroupType: String, Codable, Sendable, CaseIterable, Identifiable {
    case recurringDinner = "recurring_dinner"
    case tandaSavings = "tanda_savings"
    case sportsTeam = "sports_team"
    case studyGroup = "study_group"
    case band, poker, family, travel, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recurringDinner: "Cena recurrente"
        case .tandaSavings:    "Tanda de ahorro"
        case .sportsTeam:      "Equipo deportivo"
        case .studyGroup:      "Grupo de estudio"
        case .band:            "Banda"
        case .poker:           "Poker night"
        case .family:          "Familia"
        case .travel:          "Viajes"
        case .other:           "Otro"
        }
    }

    var copy: String {
        switch self {
        case .recurringDinner: "Cena semanal o mensual con anfitrión rotativo"
        case .tandaSavings:    "Pool rotatorio de ahorro"
        case .sportsTeam:      "Partido semanal con posiciones"
        case .studyGroup:      "Club de lectura, jevruta, etc."
        case .band:            "Ensemble musical o creativo"
        case .poker:           "Noche de juego con pots"
        case .family:          "Comidas de domingo, fiestas"
        case .travel:          "Grupo de viajes con fondo común"
        case .other:           "Define el tuyo"
        }
    }

    var symbolName: String {
        switch self {
        case .recurringDinner: "fork.knife"
        case .tandaSavings:    "dollarsign.circle"
        case .sportsTeam:      "figure.run"
        case .studyGroup:      "book.closed"
        case .band:            "music.note"
        case .poker:           "suit.spade"
        case .family:          "house"
        case .travel:          "airplane"
        case .other:           "square.grid.2x2"
        }
    }

    var hasRecurringDefaults: Bool {
        switch self {
        case .recurringDinner, .sportsTeam, .studyGroup, .poker, .family, .travel: true
        case .tandaSavings, .band, .other: false
        }
    }

    var defaultEventLabel: String {
        switch self {
        case .recurringDinner: "Cena"
        case .tandaSavings:    "Tanda"
        case .sportsTeam:      "Partido"
        case .studyGroup:      "Sesión"
        case .band:            "Ensayo"
        case .poker:           "Mesa"
        case .family:          "Comida"
        case .travel:          "Viaje"
        case .other:           "Evento"
        }
    }
}
```

- [ ] **Step 4: Implement `Profile.swift`**

```swift
import Foundation

struct Profile: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var displayName: String
    var avatarUrl: String?
    var phone: String?

    var needsOnboarding: Bool { displayName.trimmingCharacters(in: .whitespaces).isEmpty }
}
```

- [ ] **Step 5: Implement `Group.swift`**

```swift
import Foundation

struct Group: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    let groupType: GroupType
    let inviteCode: String
    let createdAt: Date
}

struct GroupDetail: Codable, Sendable {
    let group: Group
    let memberCount: Int
    let myRole: String  // "admin" | "member"
}

struct CreateGroupParams: Sendable {
    let name: String
    let description: String?
    let eventLabel: String
    let currency: String
    let groupType: GroupType
    let defaultDayOfWeek: Int?
    let defaultStartTime: String?  // "HH:mm:ss" wire format
    let defaultLocation: String?
}
```

- [ ] **Step 6: Implement `Member.swift`**

```swift
import Foundation

struct Member: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let userId: UUID
    let displayNameOverride: String?
    let role: String  // "admin" | "member"
    let active: Bool
    let joinedAt: Date
}
```

- [ ] **Step 7: Implement `ViewState.swift` and `JSONDecoder.tandas`**

```swift
import Foundation

enum ViewState<T: Sendable>: Sendable {
    case idle
    case loading
    case loaded(T)
    case empty
    case error(String)
}

extension JSONDecoder {
    static let tandas: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let tandas: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
```

- [ ] **Step 8: Implement `DesignSystem/Tokens.swift`**

```swift
import SwiftUI

enum Brand {
    static let accent = Color(red: 0.611, green: 0.482, blue: 0.957)
    static let accent2 = Color(red: 0.957, green: 0.482, blue: 0.741)
    static let accent3 = Color(red: 0.482, green: 0.741, blue: 0.957)

    static let meshColors: [Color] = [
        Color(red: 0.06, green: 0.05, blue: 0.12),
        Color(red: 0.18, green: 0.10, blue: 0.30),
        Color(red: 0.30, green: 0.10, blue: 0.40),
        Color(red: 0.10, green: 0.16, blue: 0.32),
        Color(red: 0.20, green: 0.14, blue: 0.36),
        Color(red: 0.40, green: 0.20, blue: 0.50),
        Color(red: 0.08, green: 0.08, blue: 0.20),
        Color(red: 0.22, green: 0.12, blue: 0.34),
        Color(red: 0.16, green: 0.10, blue: 0.28)
    ]

    static let groupPalette: [Color] = [
        Color(red: 0.61, green: 0.48, blue: 0.96),
        Color(red: 0.96, green: 0.48, blue: 0.74),
        Color(red: 0.48, green: 0.74, blue: 0.96),
        Color(red: 0.96, green: 0.74, blue: 0.48),
        Color(red: 0.48, green: 0.96, blue: 0.74),
        Color(red: 0.74, green: 0.96, blue: 0.48),
        Color(red: 0.96, green: 0.48, blue: 0.48),
        Color(red: 0.48, green: 0.96, blue: 0.96),
        Color(red: 0.96, green: 0.96, blue: 0.48),
        Color(red: 0.74, green: 0.48, blue: 0.96),
        Color(red: 0.96, green: 0.61, blue: 0.74),
        Color(red: 0.61, green: 0.96, blue: 0.74)
    ]

    static func paletteColor(forGroupId id: UUID) -> Color {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return groupPalette[sum % groupPalette.count]
    }

    enum Status {
        static let event = Color.green
        static let fine = Color.yellow
        static let vote = Color.cyan
        static let turn = Color.purple
    }

    enum Radius {
        static let card: CGFloat = 22
        static let pill: CGFloat = 999
        static let chip: CGFloat = 14
        static let field: CGFloat = 18
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}
```

- [ ] **Step 9: Implement `DesignSystem/Typography.swift`**

```swift
import SwiftUI

extension Font {
    static let tandaHero = Font.system(size: 28, weight: .bold, design: .rounded)
    static let tandaTitle = Font.system(size: 18, weight: .semibold)
    static let tandaBody = Font.system(size: 15, weight: .regular)
    static let tandaCaption = Font.system(size: 11, weight: .medium).monospacedDigit()
    static let tandaAmount = Font.system(size: 24, weight: .bold, design: .rounded).monospacedDigit()
}
```

- [ ] **Step 10: Implement `DesignSystem/AdaptiveGlass.swift`**

```swift
import SwiftUI

extension View {
    @ViewBuilder
    func adaptiveGlass<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        ModifierBody(content: self, shape: shape, tint: tint, interactive: interactive)
    }
}

private struct ModifierBody<Content: View, S: Shape>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let content: Content
    let shape: S
    let tint: Color?
    let interactive: Bool

    var body: some View {
        if reduceTransparency {
            content
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        } else {
            let style: GlassEffect = {
                let base: GlassEffect = tint.map { .tinted($0) } ?? .regular
                return interactive ? base.interactive() : base
            }()
            content.glassEffect(style, in: shape)
        }
    }
}
```

- [ ] **Step 11: Implement `DesignSystem/MeshBackground.swift`**

```swift
import SwiftUI

struct MeshBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                .init(x: 0, y: 0),    .init(x: 0.5, y: 0),    .init(x: 1, y: 0),
                .init(x: 0, y: 0.5),  .init(x: 0.5, y: 0.5 + 0.04 * sin(phase)),  .init(x: 1, y: 0.5),
                .init(x: 0, y: 1),    .init(x: 0.5, y: 1),    .init(x: 1, y: 1)
            ],
            colors: Brand.meshColors
        )
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}
```

- [ ] **Step 12: Implement `DesignSystem/Components/GlassCard.swift`**

```swift
import SwiftUI

struct GlassCard<Content: View>: View {
    let tint: Color?
    let interactive: Bool
    let content: () -> Content

    init(tint: Color? = nil, interactive: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.tint = tint
        self.interactive = interactive
        self.content = content
    }

    var body: some View {
        content()
            .padding(Brand.Spacing.l)
            .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous), tint: tint, interactive: interactive)
    }
}
```

- [ ] **Step 13: Implement `DesignSystem/Components/GlassCapsuleButton.swift`**

```swift
import SwiftUI

struct GlassCapsuleButton: View {
    let title: String
    let systemImage: String?
    let tint: Color
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, tint: Color = Brand.accent, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Brand.Spacing.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.tandaTitle)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Brand.Spacing.xl)
            .padding(.vertical, Brand.Spacing.m + 2)
            .frame(maxWidth: .infinity)
            .adaptiveGlass(Capsule(), tint: tint, interactive: true)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: triggerKey)
    }

    @State private var triggerKey: Int = 0
}
```

- [ ] **Step 14: Implement `DesignSystem/Components/Field.swift`**

```swift
import SwiftUI

struct Field<Content: View>: View {
    let label: String?
    let description: String?
    let error: String?
    let content: Content

    init(label: String? = nil, description: String? = nil, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.description = description
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.xs) {
            if let label {
                Text(label).font(.tandaBody.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            }
            content
                .padding(.horizontal, Brand.Spacing.m)
                .padding(.vertical, Brand.Spacing.m)
                .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
            if let error {
                Text(error).font(.tandaCaption).foregroundStyle(.red)
            } else if let description {
                Text(description).font(.tandaCaption).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
```

- [ ] **Step 15: Re-run tests; expected to pass**

Ask user to run:

```bash
cd ios && make project && make test
```

Expected: 3 tests pass (`groupTypeSnakeCase`, `groupDecode`, `profileEmptyName`).

- [ ] **Step 16: Commit**

```bash
git add ios/Tandas/Models ios/Tandas/DesignSystem ios/TandasTests/ModelsTests.swift
git commit -m "feat(ios): models + ViewState + DesignSystem foundation (tokens, glass, mesh)"
```

---

## Task 5: AuthService (protocol, Live, Mock)

**Files:**
- Create: `ios/Tandas/Supabase/AuthService.swift`
- Create: `ios/TandasTests/MockAuthServiceTests.swift`

- [ ] **Step 1: Write Mock-based tests first**

`ios/TandasTests/MockAuthServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("MockAuthService")
struct MockAuthServiceTests {
    @Test("starts with no session")
    func startsLoggedOut() async throws {
        let svc = MockAuthService()
        let s = await svc.session
        #expect(s == nil)
    }

    @Test("phone OTP happy path")
    func phoneOTP() async throws {
        let svc = MockAuthService()
        try await svc.sendPhoneOTP("+5215555550000")
        let session = try await svc.verifyPhoneOTP("+5215555550000", code: "123456")
        #expect(session.user.id != UUID())  // any user id
        let after = await svc.session
        #expect(after != nil)
    }

    @Test("wrong OTP throws")
    func wrongOTP() async throws {
        let svc = MockAuthService()
        try await svc.sendPhoneOTP("+5215555550000")
        await #expect(throws: AuthError.invalidOTP) {
            _ = try await svc.verifyPhoneOTP("+5215555550000", code: "999999")
        }
    }

    @Test("signOut clears session")
    func signOutClears() async throws {
        let svc = MockAuthService()
        _ = try await svc.signInWithApple()
        try await svc.signOut()
        let s = await svc.session
        #expect(s == nil)
    }
}
```

- [ ] **Step 2: Run; expected to fail**

```bash
cd ios && make test
```

Expected: compile errors for `MockAuthService`, `AuthError`.

- [ ] **Step 3: Implement `AuthService.swift`**

```swift
import Foundation
import Supabase

enum AuthError: Error, Equatable {
    case invalidOTP
    case appleCancelled
    case appleNoToken
    case network
    case unknown(String)
}

struct AppSession: Sendable, Equatable {
    let user: AppUser
    let accessToken: String
}

struct AppUser: Sendable, Equatable {
    let id: UUID
    let email: String?
    let phone: String?
}

protocol AuthService: Actor {
    var session: AppSession? { get async }
    var sessionStream: AsyncStream<AppSession?> { get }

    func signInWithApple() async throws -> AppSession
    func sendPhoneOTP(_ phone: String) async throws
    func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession
    func sendEmailOTP(_ email: String) async throws
    func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession
    func signOut() async throws
}

// MARK: - Mock

actor MockAuthService: AuthService {
    private var _session: AppSession?
    private var _continuation: AsyncStream<AppSession?>.Continuation?
    private(set) lazy var sessionStream: AsyncStream<AppSession?> = makeStream()

    private func makeStream() -> AsyncStream<AppSession?> {
        AsyncStream { continuation in
            self.assignContinuation(continuation)
        }
    }

    private func assignContinuation(_ c: AsyncStream<AppSession?>.Continuation) {
        self._continuation = c
        c.yield(_session)
    }

    var session: AppSession? { _session }

    func signInWithApple() async throws -> AppSession {
        let s = AppSession(
            user: AppUser(id: UUID(), email: "apple@example.com", phone: nil),
            accessToken: "mock-apple-token"
        )
        _session = s
        _continuation?.yield(s)
        return s
    }

    func sendPhoneOTP(_ phone: String) async throws { /* no-op */ }

    func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession {
        guard code == "123456" else { throw AuthError.invalidOTP }
        let s = AppSession(
            user: AppUser(id: UUID(), email: nil, phone: phone),
            accessToken: "mock-phone-token"
        )
        _session = s
        _continuation?.yield(s)
        return s
    }

    func sendEmailOTP(_ email: String) async throws { /* no-op */ }

    func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession {
        guard code == "123456" else { throw AuthError.invalidOTP }
        let s = AppSession(
            user: AppUser(id: UUID(), email: email, phone: nil),
            accessToken: "mock-email-token"
        )
        _session = s
        _continuation?.yield(s)
        return s
    }

    func signOut() async throws {
        _session = nil
        _continuation?.yield(nil)
    }
}

// MARK: - Live

actor LiveAuthService: AuthService {
    private let client: SupabaseClient
    private var _session: AppSession?
    private var _continuation: AsyncStream<AppSession?>.Continuation?
    private(set) lazy var sessionStream: AsyncStream<AppSession?> = makeStream()
    private var observerTask: Task<Void, Never>?

    init(client: SupabaseClient) {
        self.client = client
        Task { await self.bootstrap() }
    }

    private func makeStream() -> AsyncStream<AppSession?> {
        AsyncStream { continuation in
            self.assignContinuation(continuation)
        }
    }

    private func assignContinuation(_ c: AsyncStream<AppSession?>.Continuation) {
        _continuation = c
        c.yield(_session)
    }

    private func bootstrap() async {
        if let session = try? await client.auth.session {
            _session = session.toAppSession()
            _continuation?.yield(_session)
        }
        observerTask = Task { [weak self] in
            for await change in await self?.client.auth.authStateChanges ?? AsyncStream { _ in } {
                let mapped = change.session?.toAppSession()
                await self?.applySession(mapped)
            }
        }
    }

    private func applySession(_ s: AppSession?) async {
        _session = s
        _continuation?.yield(s)
    }

    var session: AppSession? { _session }

    func signInWithApple() async throws -> AppSession {
        // The actual ASAuthorizationController flow runs on main actor in the View.
        // This entry point assumes the caller has already obtained the identity token.
        throw AuthError.unknown("Use signInWithApple(idToken:) on LiveAuthService directly.")
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> AppSession {
        do {
            let response = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
            let mapped = response.toAppSession()
            _session = mapped
            _continuation?.yield(mapped)
            return mapped
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    func sendPhoneOTP(_ phone: String) async throws {
        try await client.auth.signInWithOTP(phone: phone)
    }

    func verifyPhoneOTP(_ phone: String, code: String) async throws -> AppSession {
        do {
            let session = try await client.auth.verifyOTP(phone: phone, token: code, type: .sms)
            let mapped = session.toAppSession()
            _session = mapped
            _continuation?.yield(mapped)
            return mapped
        } catch {
            throw AuthError.invalidOTP
        }
    }

    func sendEmailOTP(_ email: String) async throws {
        try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    func verifyEmailOTP(_ email: String, code: String) async throws -> AppSession {
        do {
            let session = try await client.auth.verifyOTP(email: email, token: code, type: .email)
            let mapped = session.toAppSession()
            _session = mapped
            _continuation?.yield(mapped)
            return mapped
        } catch {
            throw AuthError.invalidOTP
        }
    }

    func signOut() async throws {
        try await client.auth.signOut()
        _session = nil
        _continuation?.yield(nil)
    }
}

private extension Supabase.Session {
    func toAppSession() -> AppSession {
        AppSession(
            user: AppUser(
                id: user.id,
                email: user.email,
                phone: user.phone
            ),
            accessToken: accessToken
        )
    }
}
```

- [ ] **Step 4: Run tests; expected to pass**

```bash
cd ios && make test
```

Expected: 4 mock-auth tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Supabase/AuthService.swift ios/TandasTests/MockAuthServiceTests.swift
git commit -m "feat(ios): AuthService protocol + MockAuthService + LiveAuthService"
```

---

## Task 6: ProfileRepository

**Files:**
- Create: `ios/Tandas/Supabase/Repos/ProfileRepository.swift`
- Create: `ios/TandasTests/MockProfileRepositoryTests.swift`

- [ ] **Step 1: Write Mock tests first**

`ios/TandasTests/MockProfileRepositoryTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("MockProfileRepository")
struct MockProfileRepositoryTests {
    @Test("loads default profile (empty display_name)")
    func loadsEmpty() async throws {
        let repo = MockProfileRepository()
        let p = try await repo.loadMine()
        #expect(p.displayName.isEmpty)
        #expect(p.needsOnboarding)
    }

    @Test("update display_name persists in mock state")
    func updates() async throws {
        let repo = MockProfileRepository()
        try await repo.updateDisplayName("Jose")
        let p = try await repo.loadMine()
        #expect(p.displayName == "Jose")
        #expect(!p.needsOnboarding)
    }
}
```

- [ ] **Step 2: Run, expect fail**

```bash
cd ios && make test
```

Expected: compile errors for `MockProfileRepository`.

- [ ] **Step 3: Implement `ProfileRepository.swift`**

```swift
import Foundation
import Supabase

protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
}

actor MockProfileRepository: ProfileRepository {
    private var _profile: Profile

    init(seed: Profile = Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil)) {
        self._profile = seed
    }

    func loadMine() async throws -> Profile { _profile }

    func updateDisplayName(_ name: String) async throws {
        _profile.displayName = name
    }
}

actor LiveProfileRepository: ProfileRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func loadMine() async throws -> Profile {
        guard let userId = try await client.auth.session.user.id as UUID? else {
            throw NSError(domain: "ProfileRepo", code: 401)
        }
        let row: Profile = try await client
            .from("profiles")
            .select("id, display_name, avatar_url, phone")
            .eq("id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return row
    }

    func updateDisplayName(_ name: String) async throws {
        guard let userId = try await client.auth.session.user.id as UUID? else {
            throw NSError(domain: "ProfileRepo", code: 401)
        }
        try await client
            .from("profiles")
            .update(["display_name": name])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
cd ios && make test
```

Expected: 2 profile-mock tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Supabase/Repos/ProfileRepository.swift \
        ios/TandasTests/MockProfileRepositoryTests.swift
git commit -m "feat(ios): ProfileRepository protocol + Live + Mock"
```

---

## Task 7: GroupsRepository

**Files:**
- Create: `ios/Tandas/Supabase/Repos/GroupsRepository.swift`
- Create: `ios/TandasTests/MockGroupsRepositoryTests.swift`

- [ ] **Step 1: Write Mock tests first**

`ios/TandasTests/MockGroupsRepositoryTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("MockGroupsRepository")
struct MockGroupsRepositoryTests {
    @Test("listMine starts empty")
    func listEmpty() async throws {
        let repo = MockGroupsRepository()
        let groups = try await repo.listMine()
        #expect(groups.isEmpty)
    }

    @Test("create persists and listMine returns it")
    func createAndList() async throws {
        let repo = MockGroupsRepository()
        let params = CreateGroupParams(
            name: "Cena martes",
            description: nil,
            eventLabel: "Cena",
            currency: "MXN",
            groupType: .recurringDinner,
            defaultDayOfWeek: 2,
            defaultStartTime: "20:00:00",
            defaultLocation: "Casa de Jose"
        )
        let g = try await repo.create(params)
        #expect(g.name == "Cena martes")
        #expect(g.groupType == .recurringDinner)
        let all = try await repo.listMine()
        #expect(all.count == 1)
    }

    @Test("joinByCode finds preseeded group")
    func joinByCode() async throws {
        let preseed = Group(
            id: UUID(), name: "Tanda viejos", description: nil,
            groupType: .tandaSavings, inviteCode: "tandaaaa",
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [preseed])
        let g = try await repo.joinByCode("tandaaaa")
        #expect(g.id == preseed.id)
    }

    @Test("joinByCode wrong code throws")
    func joinByCodeWrong() async throws {
        let repo = MockGroupsRepository()
        await #expect(throws: GroupsError.inviteCodeNotFound) {
            _ = try await repo.joinByCode("nope0000")
        }
    }
}
```

- [ ] **Step 2: Run, expect fail**

```bash
cd ios && make test
```

Expected: compile errors.

- [ ] **Step 3: Implement `GroupsRepository.swift`**

```swift
import Foundation
import Supabase

enum GroupsError: Error, Equatable {
    case inviteCodeNotFound
    case rpcFailed(String)
    case notFound
}

protocol GroupsRepository: Actor {
    func listMine() async throws -> [Group]
    func get(_ id: UUID) async throws -> GroupDetail
    func create(_ params: CreateGroupParams) async throws -> Group
    func joinByCode(_ code: String) async throws -> Group
    func leave(_ id: UUID) async throws
    func members(of groupId: UUID) async throws -> [Member]
}

// MARK: - Mock

actor MockGroupsRepository: GroupsRepository {
    private var _groups: [Group]
    private var _members: [UUID: [Member]] = [:]

    init(seed: [Group] = []) { self._groups = seed }

    func listMine() async throws -> [Group] { _groups }

    func get(_ id: UUID) async throws -> GroupDetail {
        guard let g = _groups.first(where: { $0.id == id }) else { throw GroupsError.notFound }
        return GroupDetail(group: g, memberCount: _members[id]?.count ?? 1, myRole: "admin")
    }

    func create(_ p: CreateGroupParams) async throws -> Group {
        let g = Group(
            id: UUID(), name: p.name, description: p.description,
            groupType: p.groupType,
            inviteCode: String(UUID().uuidString.prefix(8)).lowercased(),
            createdAt: .now
        )
        _groups.append(g)
        return g
    }

    func joinByCode(_ code: String) async throws -> Group {
        guard let g = _groups.first(where: { $0.inviteCode == code }) else {
            throw GroupsError.inviteCodeNotFound
        }
        return g
    }

    func leave(_ id: UUID) async throws {
        _groups.removeAll { $0.id == id }
    }

    func members(of groupId: UUID) async throws -> [Member] {
        _members[groupId] ?? []
    }
}

// MARK: - Live

actor LiveGroupsRepository: GroupsRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listMine() async throws -> [Group] {
        let userId = try await client.auth.session.user.id
        struct Row: Decodable { let groups: Group }
        let rows: [Row] = try await client
            .from("group_members")
            .select("groups(id, name, description, group_type, invite_code, created_at)")
            .eq("user_id", value: userId.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
        return rows.map(\.groups)
    }

    func get(_ id: UUID) async throws -> GroupDetail {
        let group: Group = try await client
            .from("groups")
            .select("id, name, description, group_type, invite_code, created_at")
            .eq("id", value: id.uuidString.lowercased())
            .single()
            .execute()
            .value
        struct CountRow: Decodable { let count: Int }
        let countRow: [CountRow] = try await client
            .from("group_members")
            .select("count", count: .exact, head: false)
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
        let userId = try await client.auth.session.user.id
        struct RoleRow: Decodable { let role: String }
        let role: RoleRow? = try? await client
            .from("group_members")
            .select("role")
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return GroupDetail(
            group: group,
            memberCount: countRow.first?.count ?? 1,
            myRole: role?.role ?? "member"
        )
    }

    func create(_ p: CreateGroupParams) async throws -> Group {
        struct Params: Encodable {
            let p_name: String
            let p_description: String?
            let p_event_label: String
            let p_currency: String
            let p_timezone: String
            let p_default_day: Int?
            let p_default_time: String?
            let p_default_location: String?
            let p_voting_threshold: Double
            let p_voting_quorum: Double
            let p_fund_enabled: Bool
            let p_group_type: String
        }
        let params = Params(
            p_name: p.name,
            p_description: p.description,
            p_event_label: p.eventLabel,
            p_currency: p.currency,
            p_timezone: "America/Mexico_City",
            p_default_day: p.defaultDayOfWeek,
            p_default_time: p.defaultStartTime,
            p_default_location: p.defaultLocation,
            p_voting_threshold: 0.5,
            p_voting_quorum: 0.5,
            p_fund_enabled: true,
            p_group_type: p.groupType.rawValue
        )
        do {
            let g: Group = try await client
                .rpc("create_group_with_admin", params: params)
                .execute()
                .value
            return g
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    func joinByCode(_ code: String) async throws -> Group {
        struct Params: Encodable { let p_code: String }
        do {
            let g: Group = try await client
                .rpc("join_group_by_code", params: Params(p_code: code))
                .execute()
                .value
            return g
        } catch {
            throw GroupsError.inviteCodeNotFound
        }
    }

    func leave(_ id: UUID) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("group_members")
            .update(["active": false])
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
    }

    func members(of groupId: UUID) async throws -> [Member] {
        try await client
            .from("group_members")
            .select("id, group_id, user_id, display_name_override, role, active, joined_at")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
cd ios && make test
```

Expected: 4 groups-mock tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Supabase/Repos/GroupsRepository.swift \
        ios/TandasTests/MockGroupsRepositoryTests.swift
git commit -m "feat(ios): GroupsRepository protocol + Live (RPC) + Mock"
```

---

## Task 8: TandasApp + AuthGate routing

**Files:**
- Create: `ios/Tandas/Shell/AuthGate.swift`
- Modify: `ios/Tandas/TandasApp.swift`

- [ ] **Step 1: Implement `AuthGate.swift`**

```swift
import SwiftUI

@MainActor
@Observable
final class AppState {
    var session: AppSession?
    var profile: Profile?
    var groups: [Group] = []
    var isBootstrapping: Bool = true

    let auth: any AuthService
    let profileRepo: any ProfileRepository
    let groupsRepo: any GroupsRepository

    init(
        auth: any AuthService,
        profileRepo: any ProfileRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.auth = auth
        self.profileRepo = profileRepo
        self.groupsRepo = groupsRepo
    }

    func start() async {
        for await s in await auth.sessionStream {
            self.session = s
            if s != nil {
                await refreshProfileAndGroups()
            } else {
                self.profile = nil
                self.groups = []
            }
            self.isBootstrapping = false
        }
    }

    func refreshProfileAndGroups() async {
        async let p = (try? await profileRepo.loadMine())
        async let g = ((try? await groupsRepo.listMine()) ?? [])
        let (profile, groups) = await (p, g)
        self.profile = profile
        self.groups = groups
    }
}

struct AuthGate: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.isBootstrapping {
                BootstrappingView()
            } else if app.session == nil {
                LoginView()
            } else if let profile = app.profile, profile.needsOnboarding {
                OnboardingView()
            } else if app.profile == nil {
                BootstrappingView()  // brief flicker while profile loads
            } else if app.groups.isEmpty {
                EmptyGroupsView()
            } else {
                GroupsListView()
            }
        }
        .task { await app.start() }
    }
}

struct BootstrappingView: View {
    var body: some View {
        ZStack {
            MeshBackground()
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }
}
```

- [ ] **Step 2: Update `TandasApp.swift` for environment-driven AppState**

```swift
import SwiftUI
import Supabase

@main
struct TandasApp: App {
    @State private var appState: AppState

    init() {
        let client = SupabaseEnvironment.shared
        let auth = LiveAuthService(client: client)
        let profile = LiveProfileRepository(client: client)
        let groups = LiveGroupsRepository(client: client)
        _appState = State(initialValue: AppState(
            auth: auth, profileRepo: profile, groupsRepo: groups
        ))
    }

    var body: some Scene {
        WindowGroup {
            AuthGate()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}

// Stub views — implemented in tasks 9, 11, 12, 16
struct LoginView: View { var body: some View { Text("LoginView (stub)").foregroundStyle(.white) } }
struct OnboardingView: View { var body: some View { Text("OnboardingView (stub)").foregroundStyle(.white) } }
struct EmptyGroupsView: View { var body: some View { Text("EmptyGroupsView (stub)").foregroundStyle(.white) } }
struct GroupsListView: View { var body: some View { Text("GroupsListView (stub)").foregroundStyle(.white) } }
```

- [ ] **Step 3: Build, expect green**

```bash
cd ios && make project && make build
```

Expected: BUILD SUCCEEDED. App launches, briefly shows ProgressView, then shows "LoginView (stub)" because no session.

- [ ] **Step 4: Commit**

```bash
git add ios/Tandas/Shell/AuthGate.swift ios/Tandas/TandasApp.swift
git commit -m "feat(ios): AuthGate routing + AppState observable + service wiring"
```

---

## Task 9: LoginView (SiwA + Phone + Email tabs)

**Files:**
- Create: `ios/Tandas/Features/Auth/LoginView.swift`
- Create: `ios/Tandas/Features/Auth/AuthViewModel.swift`
- Create: `ios/TandasTests/LoginViewSnapshotTests.swift`
- Modify: `ios/Tandas/TandasApp.swift` (remove LoginView stub)

- [ ] **Step 1: Implement `AuthViewModel.swift`**

```swift
import SwiftUI
import AuthenticationServices

enum AuthMethod: String, CaseIterable, Identifiable {
    case phone, email
    var id: String { rawValue }
    var label: String { self == .phone ? "Teléfono" : "Email" }
}

@MainActor
@Observable
final class AuthViewModel {
    var method: AuthMethod = .phone
    var phone: String = "+52"
    var email: String = ""
    var isSending: Bool = false
    var errorMessage: String?
    var pendingChannel: OTPChannel?

    let auth: any AuthService

    init(auth: any AuthService) { self.auth = auth }

    func sendOTP() async {
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            switch method {
            case .phone:
                let phoneTrim = phone.trimmingCharacters(in: .whitespaces)
                guard phoneTrim.hasPrefix("+") && phoneTrim.count >= 10 else {
                    errorMessage = "Número inválido. Usa formato +52…"
                    return
                }
                try await auth.sendPhoneOTP(phoneTrim)
                pendingChannel = .phone(phoneTrim)
            case .email:
                let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard emailTrim.contains("@") else {
                    errorMessage = "Email inválido."
                    return
                }
                try await auth.sendEmailOTP(emailTrim)
                pendingChannel = .email(emailTrim)
            }
        } catch {
            errorMessage = "No se pudo enviar el código. Intenta de nuevo."
        }
    }
}

enum OTPChannel: Identifiable, Hashable {
    case phone(String), email(String)

    var id: String {
        switch self { case .phone(let p): "phone:\(p)"; case .email(let e): "email:\(e)" }
    }

    var label: String {
        switch self { case .phone(let p): p; case .email(let e): e }
    }

    var isPhone: Bool { if case .phone = self { true } else { false } }
}
```

- [ ] **Step 2: Implement `LoginView.swift`**

```swift
import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @Environment(AppState.self) private var app
    @State private var vm: AuthViewModel?
    @State private var nonce: String = AppleNonce.generate()

    var body: some View {
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(spacing: Brand.Spacing.xl) {
                    Spacer().frame(height: Brand.Spacing.xxl * 2)
                    header
                    appleButton
                    divider
                    methodPicker
                    inputField
                    sendButton
                    if let error = vm?.errorMessage {
                        Text(error).font(.tandaCaption).foregroundStyle(.red)
                    }
                    Spacer().frame(height: Brand.Spacing.xl)
                    footer
                }
                .padding(.horizontal, Brand.Spacing.xl)
            }
        }
        .navigationDestination(item: bindingForChannel()) { channel in
            OTPInputView(channel: channel)
        }
        .onAppear {
            if vm == nil { vm = AuthViewModel(auth: app.auth) }
        }
    }

    private var header: some View {
        VStack(spacing: Brand.Spacing.s) {
            Text("Tandas")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("La vida en grupo, sin pleitos.")
                .font(.tandaBody)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonce.sha256(nonce)
        } onCompletion: { result in
            handleAppleCompletion(result)
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 52)
        .clipShape(Capsule())
    }

    private var divider: some View {
        HStack {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
            Text("o").font(.tandaCaption).foregroundStyle(.white.opacity(0.5))
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var methodPicker: some View {
        if let vm {
            @Bindable var bvm = vm
            Picker("Método", selection: $bvm.method) {
                ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: vm.method)
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if let vm {
            @Bindable var bvm = vm
            switch vm.method {
            case .phone:
                Field(label: "Tu número", description: "Te mandamos un código de 6 dígitos por SMS.") {
                    TextField("+5215555551234", text: $bvm.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .foregroundStyle(.white)
                }
            case .email:
                Field(label: "Tu email", description: "Te mandamos un código de 6 dígitos por correo.") {
                    TextField("tu@email.com", text: $bvm.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if let vm {
            GlassCapsuleButton(vm.isSending ? "Enviando…" : "Enviarme código") {
                Task { await vm.sendOTP() }
            }
            .disabled(vm.isSending)
        }
    }

    private var footer: some View {
        Text("Al continuar aceptas las reglas que tu grupo defina.")
            .font(.tandaCaption)
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
    }

    private func bindingForChannel() -> Binding<OTPChannel?> {
        Binding(
            get: { vm?.pendingChannel },
            set: { vm?.pendingChannel = $0 }
        )
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else { return }
            let captured = nonce
            Task {
                if let live = self.vm?.auth as? LiveAuthService {
                    _ = try? await live.signInWithApple(idToken: token, nonce: captured)
                } else {
                    _ = try? await self.vm?.auth.signInWithApple()
                }
            }
        case .failure:
            break  // user cancelled; no-op
        }
    }
}

enum AppleNonce {
    static func generate() -> String {
        let chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        return String((0..<32).map { _ in chars.randomElement()! })
    }
    static func sha256(_ input: String) -> String {
        // Minimal SHA-256 wrapper using CryptoKit
        let data = Data(input.utf8)
        return data.sha256Hex
    }
}

import CryptoKit
private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 3: Write snapshot tests**

`ios/TandasTests/LoginViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("LoginView snapshots")
@MainActor
struct LoginViewSnapshotTests {
    @Test("phone tab default")
    func phone() async {
        let app = AppState(
            auth: MockAuthService(),
            profileRepo: MockProfileRepository(),
            groupsRepo: MockGroupsRepository()
        )
        let view = LoginView().environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 4: Remove `LoginView` stub from `TandasApp.swift`**

Remove the `struct LoginView: View { ... }` stub line — the real one now lives in `Features/Auth/LoginView.swift`.

- [ ] **Step 5: Run snapshot test (RECORD mode first time)**

Ask user to run with `record: true` once:

```bash
cd ios && SNAPSHOT_RECORD=1 make test
```

Expected: snapshot recorded under `ios/TandasTests/__Snapshots__/LoginViewSnapshotTests/phone.png`.

User reviews PNG visually; if it looks right (mesh + apple button + tab + field), commit it.

- [ ] **Step 6: Run snapshot test in compare mode**

```bash
cd ios && make test
```

Expected: passes — pixel match.

- [ ] **Step 7: Manual smoke**

User taps Phone tab, types `+5215555551234`, presses "Enviarme código". Expected: SMS received in real device, console shows the OTP send call. (Email path same with real email.)

- [ ] **Step 8: Commit**

```bash
git add ios/Tandas/Features/Auth/{LoginView,AuthViewModel}.swift \
        ios/TandasTests/LoginViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/ \
        ios/Tandas/TandasApp.swift
git commit -m "feat(ios): LoginView with SiwA + Phone/Email OTP tabs"
```

---

## Task 10: OTPInputView with auto-submit and resend

**Files:**
- Create: `ios/Tandas/Features/Auth/OTPInputView.swift`
- Create: `ios/Tandas/DesignSystem/Components/OTPInput.swift`
- Create: `ios/TandasTests/OTPInputViewSnapshotTests.swift`

- [ ] **Step 1: Implement `OTPInput.swift` (the 6-slot component)**

```swift
import SwiftUI

struct OTPInput: View {
    @Binding var code: String
    @FocusState private var isFocused: Bool
    var disabled: Bool = false

    var body: some View {
        ZStack {
            HStack(spacing: Brand.Spacing.s) {
                ForEach(0..<6, id: \.self) { index in
                    OTPSlot(char: char(at: index), focused: isFocused && index == code.count)
                }
            }
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.001)
                .frame(width: 1, height: 1)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.prefix(6).filter(\.isNumber))
                    if filtered != newValue { code = filtered }
                }
                .disabled(disabled)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
    }

    private func char(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}

private struct OTPSlot: View {
    let char: String
    let focused: Bool
    var body: some View {
        ZStack {
            Text(char.isEmpty ? " " : char)
                .font(.tandaAmount)
                .foregroundStyle(.white)
        }
        .frame(width: 46, height: 56)
        .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.field), tint: focused ? Brand.accent.opacity(0.4) : nil)
    }
}
```

- [ ] **Step 2: Implement `OTPInputView.swift`**

```swift
import SwiftUI

struct OTPInputView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let channel: OTPChannel

    @State private var code: String = ""
    @State private var isVerifying: Bool = false
    @State private var errorMessage: String?
    @State private var resendIn: Int = 30
    @State private var resendTimer: Task<Void, Never>?
    @State private var feedbackTrigger: Int = 0

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: Brand.Spacing.xl) {
                header
                OTPInput(code: $code, disabled: isVerifying)
                    .onChange(of: code) { _, newValue in
                        if newValue.count == 6 && !isVerifying { Task { await verify() } }
                    }
                if let errorMessage {
                    Text(errorMessage).font(.tandaCaption).foregroundStyle(.red)
                }
                resendButton
                Spacer()
            }
            .padding(.horizontal, Brand.Spacing.xl)
            .padding(.top, Brand.Spacing.xxl)
        }
        .toolbar { ToolbarItem(placement: .topBarLeading) { backButton } }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { startResendTimer() }
        .onDisappear { resendTimer?.cancel() }
        .sensoryFeedback(.success, trigger: feedbackTrigger)
    }

    private var header: some View {
        VStack(spacing: Brand.Spacing.s) {
            Text("Escribe el código")
                .font(.tandaHero).foregroundStyle(.white)
            Text("Te lo enviamos a ")
                .font(.tandaBody).foregroundStyle(.white.opacity(0.7))
            + Text(channel.label)
                .font(.tandaBody.weight(.semibold)).foregroundStyle(.white)
        }
        .multilineTextAlignment(.center)
    }

    private var resendButton: some View {
        Button {
            Task { await resend() }
        } label: {
            Text(resendIn > 0 ? "Reenviar en \(resendIn)s" : "Reenviar código")
                .font(.tandaCaption).foregroundStyle(.white.opacity(resendIn > 0 ? 0.4 : 0.85))
                .underline(resendIn == 0)
        }
        .disabled(resendIn > 0)
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text(channel.isPhone ? "Cambiar número" : "Cambiar email")
            }
            .font(.tandaBody)
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func verify() async {
        isVerifying = true
        errorMessage = nil
        defer { isVerifying = false }
        do {
            switch channel {
            case .phone(let phone):
                _ = try await app.auth.verifyPhoneOTP(phone, code: code)
            case .email(let email):
                _ = try await app.auth.verifyEmailOTP(email, code: code)
            }
            feedbackTrigger &+= 1
            // AuthGate will navigate automatically once session changes
        } catch {
            errorMessage = "Código incorrecto. Vuelve a intentarlo."
            code = ""
        }
    }

    private func resend() async {
        do {
            switch channel {
            case .phone(let p): try await app.auth.sendPhoneOTP(p)
            case .email(let e): try await app.auth.sendEmailOTP(e)
            }
            startResendTimer()
        } catch {
            errorMessage = "No se pudo reenviar. Espera un momento."
        }
    }

    private func startResendTimer() {
        resendIn = 30
        resendTimer?.cancel()
        resendTimer = Task {
            while !Task.isCancelled && resendIn > 0 {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { resendIn -= 1 }
            }
        }
    }
}
```

- [ ] **Step 3: Snapshot test**

`ios/TandasTests/OTPInputViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("OTPInputView snapshots")
@MainActor
struct OTPInputViewSnapshotTests {
    @Test("phone channel empty code")
    func phoneEmpty() async {
        let app = AppState(
            auth: MockAuthService(),
            profileRepo: MockProfileRepository(),
            groupsRepo: MockGroupsRepository()
        )
        let view = NavigationStack {
            OTPInputView(channel: .phone("+5215555551234"))
        }
        .environment(app)
        .preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 4: Record + verify**

```bash
cd ios && SNAPSHOT_RECORD=1 make test
cd ios && make test
```

Expected: first run records, second run compares green.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Features/Auth/OTPInputView.swift \
        ios/Tandas/DesignSystem/Components/OTPInput.swift \
        ios/TandasTests/OTPInputViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/
git commit -m "feat(ios): OTPInputView 6-slot auto-submit + 30s resend cooldown"
```

---

## Task 11: OnboardingView (display_name)

**Files:**
- Create: `ios/Tandas/Features/Auth/OnboardingView.swift`
- Create: `ios/TandasTests/OnboardingViewSnapshotTests.swift`
- Modify: `ios/Tandas/TandasApp.swift` (remove stub)

- [ ] **Step 1: Implement `OnboardingView.swift`**

```swift
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var name: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var feedback: Int = 0

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: Brand.Spacing.xl) {
                Spacer()
                VStack(spacing: Brand.Spacing.m) {
                    Text("¿Cómo te llaman?").font(.tandaHero).foregroundStyle(.white)
                    Text("Así te van a ver tus grupos.").font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                }
                .multilineTextAlignment(.center)
                Field(label: "Tu nombre", error: errorMessage) {
                    TextField("Jose", text: $name)
                        .textContentType(.name)
                        .foregroundStyle(.white)
                        .font(.tandaTitle)
                }
                GlassCapsuleButton(isSubmitting ? "Guardando…" : "Continuar") {
                    Task { await submit() }
                }
                .disabled(!canSubmit)
                Spacer()
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
        .sensoryFeedback(.success, trigger: feedback)
    }

    private func submit() async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { errorMessage = "Escribe tu nombre"; return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await app.profileRepo.updateDisplayName(clean)
            await app.refreshProfileAndGroups()
            feedback &+= 1
        } catch {
            errorMessage = "No se pudo guardar. Intenta de nuevo."
        }
    }
}
```

- [ ] **Step 2: Snapshot test**

`ios/TandasTests/OnboardingViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("OnboardingView snapshots")
@MainActor
struct OnboardingViewSnapshotTests {
    @Test("empty state")
    func empty() async {
        let app = AppState(
            auth: MockAuthService(),
            profileRepo: MockProfileRepository(),
            groupsRepo: MockGroupsRepository()
        )
        let view = OnboardingView().environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 3: Remove stub, build**

Remove `struct OnboardingView` stub from `TandasApp.swift`.

```bash
cd ios && make project && make test
```

Expected: builds and existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add ios/Tandas/Features/Auth/OnboardingView.swift \
        ios/TandasTests/OnboardingViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/ \
        ios/Tandas/TandasApp.swift
git commit -m "feat(ios): OnboardingView captures display_name and refreshes AppState"
```

---

## Task 12: EmptyGroupsView

**Files:**
- Create: `ios/Tandas/Features/Groups/EmptyGroupsView.swift`
- Create: `ios/TandasTests/EmptyGroupsViewSnapshotTests.swift`
- Modify: `ios/Tandas/TandasApp.swift` (remove stub)

- [ ] **Step 1: Implement `EmptyGroupsView.swift`**

```swift
import SwiftUI

struct EmptyGroupsView: View {
    @State private var showCreate: Bool = false
    @State private var showJoin: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                MeshBackground()
                ScrollView {
                    VStack(spacing: Brand.Spacing.xl) {
                        Spacer().frame(height: Brand.Spacing.xxl * 2)
                        VStack(spacing: Brand.Spacing.m) {
                            Text("Aún no tienes grupos")
                                .font(.tandaHero).foregroundStyle(.white)
                            Text("Crea uno o únete con un código de invitación.")
                                .font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        VStack(spacing: Brand.Spacing.m) {
                            cardButton(
                                title: "Crear un grupo",
                                copy: "Cena recurrente, tanda de ahorro, equipo deportivo…",
                                symbol: "plus.circle"
                            ) { showCreate = true }
                            cardButton(
                                title: "Unirme con código",
                                copy: "Si alguien ya creó tu grupo, pídele el código.",
                                symbol: "ticket"
                            ) { showJoin = true }
                        }
                    }
                    .padding(.horizontal, Brand.Spacing.xl)
                }
            }
            .navigationDestination(isPresented: $showCreate) { NewGroupWizard() }
            .navigationDestination(isPresented: $showJoin) { JoinByCodeView() }
        }
    }

    private func cardButton(title: String, copy: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Brand.Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.tandaTitle).foregroundStyle(.white)
                    Text(copy).font(.tandaCaption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Brand.Spacing.l)
            .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.card), interactive: true)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: showCreate || showJoin)
    }
}

// Stubs filled in tasks 13, 14
struct NewGroupWizard: View { var body: some View { Text("NewGroupWizard (stub)").foregroundStyle(.white) } }
struct JoinByCodeView: View { var body: some View { Text("JoinByCodeView (stub)").foregroundStyle(.white) } }
```

- [ ] **Step 2: Snapshot test**

`ios/TandasTests/EmptyGroupsViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("EmptyGroupsView snapshots")
@MainActor
struct EmptyGroupsViewSnapshotTests {
    @Test("default")
    func defaultState() async {
        let app = AppState(
            auth: MockAuthService(),
            profileRepo: MockProfileRepository(seed: Profile(id: UUID(), displayName: "Jose", avatarUrl: nil, phone: nil)),
            groupsRepo: MockGroupsRepository()
        )
        let view = EmptyGroupsView().environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 3: Remove stub, build, record snapshot, verify**

Remove `struct EmptyGroupsView` stub from `TandasApp.swift`. Run record + compare.

- [ ] **Step 4: Commit**

```bash
git add ios/Tandas/Features/Groups/EmptyGroupsView.swift \
        ios/TandasTests/EmptyGroupsViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/ \
        ios/Tandas/TandasApp.swift
git commit -m "feat(ios): EmptyGroupsView with crear/joinear CTAs"
```

---

## Task 13: JoinByCodeView

**Files:**
- Create: `ios/Tandas/Features/Groups/JoinByCodeView.swift`
- Create: `ios/Tandas/Features/Groups/GroupsViewModel.swift`
- Create: `ios/TandasTests/JoinByCodeViewSnapshotTests.swift`

- [ ] **Step 1: Implement `GroupsViewModel.swift`**

```swift
import SwiftUI

@MainActor
@Observable
final class GroupsViewModel {
    var joinCode: String = ""
    var joinError: String?
    var isJoining: Bool = false
    var joinedGroup: Group?

    let groupsRepo: any GroupsRepository

    init(groupsRepo: any GroupsRepository) { self.groupsRepo = groupsRepo }

    func join() async {
        let code = joinCode.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 8, code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            joinError = "El código tiene 8 caracteres."
            return
        }
        joinError = nil
        isJoining = true
        defer { isJoining = false }
        do {
            joinedGroup = try await groupsRepo.joinByCode(code)
        } catch GroupsError.inviteCodeNotFound {
            joinError = "No encontramos ese grupo. Revisa el código."
        } catch {
            joinError = "No pudimos unirte. Intenta de nuevo."
        }
    }
}
```

- [ ] **Step 2: Implement `JoinByCodeView.swift`**

```swift
import SwiftUI

struct JoinByCodeView: View {
    @Environment(AppState.self) private var app
    @State private var vm: GroupsViewModel?
    @State private var feedback: Int = 0

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: Brand.Spacing.xl) {
                Spacer().frame(height: Brand.Spacing.xl)
                VStack(spacing: Brand.Spacing.s) {
                    Text("Unirme con código").font(.tandaHero).foregroundStyle(.white)
                    Text("Pega los 8 caracteres del invite code.")
                        .font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                }
                if let vm {
                    @Bindable var bvm = vm
                    Field(label: "Código", error: vm.joinError) {
                        TextField("abc12345", text: $bvm.joinCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.tandaTitle.monospaced())
                            .foregroundStyle(.white)
                            .onChange(of: bvm.joinCode) { _, new in
                                bvm.joinCode = String(new.prefix(8))
                            }
                    }
                    GlassCapsuleButton(vm.isJoining ? "Uniéndome…" : "Unirme") {
                        Task {
                            await vm.join()
                            if vm.joinedGroup != nil {
                                feedback &+= 1
                                await app.refreshProfileAndGroups()
                            }
                        }
                    }
                    .disabled(vm.isJoining || vm.joinCode.count < 8)
                }
                Spacer()
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
        .navigationDestination(item: bindingForJoined()) { group in
            WelcomeView(group: group)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: feedback)
        .onAppear { if vm == nil { vm = GroupsViewModel(groupsRepo: app.groupsRepo) } }
    }

    private func bindingForJoined() -> Binding<Group?> {
        Binding(
            get: { vm?.joinedGroup },
            set: { vm?.joinedGroup = $0 }
        )
    }
}

// Stub filled in task 15
struct WelcomeView: View {
    let group: Group
    var body: some View { Text("Welcome to \(group.name) (stub)").foregroundStyle(.white) }
}
```

- [ ] **Step 3: Snapshot test**

`ios/TandasTests/JoinByCodeViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("JoinByCodeView snapshots")
@MainActor
struct JoinByCodeViewSnapshotTests {
    @Test("empty")
    func empty() async {
        let app = AppState(auth: MockAuthService(), profileRepo: MockProfileRepository(), groupsRepo: MockGroupsRepository())
        let view = NavigationStack { JoinByCodeView() }.environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 4: Build + record + verify**

Replace the prior `JoinByCodeView` stub from task 12. Build, snapshot record, snapshot verify.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Features/Groups/JoinByCodeView.swift \
        ios/Tandas/Features/Groups/GroupsViewModel.swift \
        ios/TandasTests/JoinByCodeViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/
git commit -m "feat(ios): JoinByCodeView calls join_group_by_code RPC"
```

---

## Task 14: NewGroupWizard (3 steps + submit)

**Files:**
- Create: `ios/Tandas/Features/Groups/NewGroupWizard.swift`
- Create: `ios/Tandas/DesignSystem/Components/TypologyCard.swift`
- Create: `ios/TandasTests/NewGroupWizardSnapshotTests.swift`

- [ ] **Step 1: Implement `TypologyCard.swift`**

```swift
import SwiftUI

struct TypologyCard: View {
    let type: GroupType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text(type.displayName)
                    .font(.tandaTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(type.copy)
                    .font(.tandaCaption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Brand.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(
                RoundedRectangle(cornerRadius: Brand.Radius.card),
                tint: isSelected ? Brand.accent.opacity(0.5) : nil,
                interactive: true
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}
```

- [ ] **Step 2: Implement `NewGroupWizard.swift`**

```swift
import SwiftUI

struct NewGroupWizard: View {
    @Environment(AppState.self) private var app
    @State private var step: Int = 0
    @State private var selectedType: GroupType?
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var eventLabel: String = ""
    @State private var dayOfWeek: Int = 2  // martes default
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
    @State private var location: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?
    @State private var createdGroup: Group?

    private let dayLabels = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: 0) {
                progressBar
                content
            }
        }
        .toolbar { toolbar }
        .navigationDestination(item: $createdGroup) { g in WelcomeView(group: g) }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let totalSteps = needsStep3 ? 3 : 2
            let progress = CGFloat(step + 1) / CGFloat(totalSteps)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(Brand.accent).frame(width: geo.size.width * progress, height: 4)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, Brand.Spacing.xl)
        .padding(.vertical, Brand.Spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: typologyStep
        case 1: identityStep
        case 2: defaultsStep
        default: EmptyView()
        }
    }

    private var typologyStep: some View {
        ScrollView {
            VStack(spacing: Brand.Spacing.l) {
                Text("¿Qué tipo de grupo es?")
                    .font(.tandaHero).foregroundStyle(.white)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Brand.Spacing.m) {
                    ForEach(GroupType.allCases) { type in
                        TypologyCard(type: type, isSelected: selectedType == type) {
                            selectedType = type
                            eventLabel = type.defaultEventLabel
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                step = 1
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
    }

    private var identityStep: some View {
        ScrollView {
            VStack(spacing: Brand.Spacing.l) {
                Text("Cuéntanos del grupo")
                    .font(.tandaHero).foregroundStyle(.white)
                Field(label: "Nombre del grupo") {
                    TextField(selectedType?.displayName ?? "", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .foregroundStyle(.white)
                }
                Field(label: "Descripción", description: "Opcional. Máx 280 caracteres.") {
                    TextField("Sirve para que los nuevos sepan de qué va.", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                        .foregroundStyle(.white)
                }
                Field(label: "Cómo le llaman al evento", description: "Cena, partido, sesión, ensayo…") {
                    TextField(selectedType?.defaultEventLabel ?? "Evento", text: $eventLabel)
                        .foregroundStyle(.white)
                }
                GlassCapsuleButton("Siguiente") {
                    step = needsStep3 ? 2 : -1
                    if !needsStep3 { Task { await submit() } }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
    }

    private var defaultsStep: some View {
        ScrollView {
            VStack(spacing: Brand.Spacing.l) {
                Text("Cuándo se juntan").font(.tandaHero).foregroundStyle(.white)
                Field(label: "Día de la semana") {
                    Picker("Día", selection: $dayOfWeek) {
                        ForEach(0..<7, id: \.self) { Text(dayLabels[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Field(label: "Hora") {
                    DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .colorScheme(.dark)
                }
                Field(label: "Lugar (opcional)") {
                    TextField("Casa de Jose, club de tenis, …", text: $location)
                        .foregroundStyle(.white)
                }
                if let error = submitError {
                    Text(error).font(.tandaCaption).foregroundStyle(.red)
                }
                GlassCapsuleButton(isSubmitting ? "Creando…" : "Crear grupo") {
                    Task { await submit() }
                }
                .disabled(isSubmitting)
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
    }

    private var needsStep3: Bool { selectedType?.hasRecurringDefaults ?? false }

    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if step > 0 { step -= 1 }
            } label: {
                Image(systemName: "chevron.left").foregroundStyle(.white)
            }
            .opacity(step > 0 ? 1 : 0)
        }
    }

    private func submit() async {
        guard let selectedType else { submitError = "Falta el tipo"; return }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let params = CreateGroupParams(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.isEmpty ? nil : description,
            eventLabel: eventLabel.isEmpty ? selectedType.defaultEventLabel : eventLabel,
            currency: "MXN",
            groupType: selectedType,
            defaultDayOfWeek: needsStep3 ? dayOfWeek : nil,
            defaultStartTime: needsStep3 ? timeFormatter.string(from: startTime) : nil,
            defaultLocation: needsStep3 ? (location.isEmpty ? nil : location) : nil
        )
        do {
            createdGroup = try await app.groupsRepo.create(params)
            await app.refreshProfileAndGroups()
        } catch GroupsError.rpcFailed(let msg) {
            submitError = "El grupo no se pudo crear: \(msg)"
        } catch {
            submitError = "Algo falló. Intenta de nuevo."
        }
    }
}
```

- [ ] **Step 3: Snapshot tests for the 3 steps**

`ios/TandasTests/NewGroupWizardSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("NewGroupWizard snapshots")
@MainActor
struct NewGroupWizardSnapshotTests {
    @Test("step1 typology grid")
    func step1() async {
        let app = AppState(auth: MockAuthService(), profileRepo: MockProfileRepository(), groupsRepo: MockGroupsRepository())
        let view = NavigationStack { NewGroupWizard() }.environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 4: Replace stub, build, record, verify**

Replace the prior `NewGroupWizard` stub from task 12. Run snapshot record and verify.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Features/Groups/NewGroupWizard.swift \
        ios/Tandas/DesignSystem/Components/TypologyCard.swift \
        ios/TandasTests/NewGroupWizardSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/
git commit -m "feat(ios): NewGroupWizard 3-step flow + 9 typology cards + RPC submit"
```

---

## Task 15: WelcomeView

**Files:**
- Create: `ios/Tandas/Features/Groups/WelcomeView.swift`
- Create: `ios/Tandas/DesignSystem/Components/WelcomeStepCard.swift`
- Create: `ios/TandasTests/WelcomeViewSnapshotTests.swift`

- [ ] **Step 1: Implement `WelcomeStepCard.swift`**

```swift
import SwiftUI

struct WelcomeStepCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Brand.Spacing.m) {
                Label {
                    Text(title).font(.tandaTitle).foregroundStyle(.white)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(Brand.accent)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

- [ ] **Step 2: Implement `WelcomeView.swift`**

```swift
import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let group: Group

    @State private var members: [Member] = []
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(spacing: Brand.Spacing.xl) {
                    hero
                    WelcomeStepCard(title: "Período de gracia", symbol: "shield.checkered") {
                        Text("Tus primeros días no generan multas. Aprende cómo funciona el grupo sin presión.")
                            .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                    }
                    WelcomeStepCard(title: "Las reglas del grupo", symbol: "list.bullet.clipboard") {
                        Text("Las reglas y multas las decide el grupo y se votan. Para ver y proponer cambios, ve a la pestaña de Reglas (próximamente).")
                            .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                    }
                    WelcomeStepCard(title: "Quiénes están", symbol: "person.3") {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else if members.isEmpty {
                            Text("Eres la primera persona del grupo.")
                                .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                        } else {
                            Text("\(members.count) miembros activos.")
                                .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    GlassCapsuleButton("Entrar al grupo") { dismiss() }
                }
                .padding(.horizontal, Brand.Spacing.xl)
                .padding(.top, Brand.Spacing.xxl)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await loadMembers() }
    }

    private var hero: some View {
        VStack(spacing: Brand.Spacing.s) {
            Text("Bienvenido a")
                .font(.tandaTitle).foregroundStyle(.white.opacity(0.7))
            Text(group.name)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(group.groupType.displayName)
                .font(.tandaCaption).foregroundStyle(.white.opacity(0.65))
        }
    }

    private func loadMembers() async {
        defer { isLoading = false }
        members = (try? await app.groupsRepo.members(of: group.id)) ?? []
    }
}
```

- [ ] **Step 3: Snapshot test**

`ios/TandasTests/WelcomeViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("WelcomeView snapshots")
@MainActor
struct WelcomeViewSnapshotTests {
    @Test("default")
    func defaultState() async {
        let g = Group(id: UUID(), name: "Cena martes", description: nil, groupType: .recurringDinner, inviteCode: "abc12345", createdAt: .now)
        let app = AppState(auth: MockAuthService(), profileRepo: MockProfileRepository(), groupsRepo: MockGroupsRepository(seed: [g]))
        let view = NavigationStack { WelcomeView(group: g) }.environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 4: Replace stub, record, verify**

Replace prior `WelcomeView` stub. Snapshot record + verify.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Features/Groups/WelcomeView.swift \
        ios/Tandas/DesignSystem/Components/WelcomeStepCard.swift \
        ios/TandasTests/WelcomeViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/
git commit -m "feat(ios): WelcomeView cultural tour after join/create"
```

---

## Task 16: GroupsListView + WalletGroupCard

**Files:**
- Create: `ios/Tandas/Features/Groups/GroupsListView.swift`
- Create: `ios/Tandas/DesignSystem/Components/WalletGroupCard.swift`
- Create: `ios/TandasTests/GroupsListViewSnapshotTests.swift`
- Modify: `ios/Tandas/TandasApp.swift` (remove stub)

- [ ] **Step 1: Implement `WalletGroupCard.swift`**

```swift
import SwiftUI

struct WalletGroupCard: View {
    let group: Group
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                HStack {
                    Image(systemName: group.groupType.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text(group.groupType.displayName)
                        .font(.tandaCaption)
                        .padding(.horizontal, Brand.Spacing.s)
                        .padding(.vertical, 4)
                        .adaptiveGlass(Capsule())
                }
                Spacer()
                Text(group.name)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(Brand.Spacing.l)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            .adaptiveGlass(
                RoundedRectangle(cornerRadius: Brand.Radius.card),
                tint: Brand.paletteColor(forGroupId: group.id),
                interactive: true
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Implement `GroupsListView.swift`**

```swift
import SwiftUI

struct GroupsListView: View {
    @Environment(AppState.self) private var app
    @State private var selected: Group?
    @State private var showCreate: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                MeshBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: Brand.Spacing.l) {
                        header
                        ForEach(app.groups) { g in
                            WalletGroupCard(group: g) { selected = g }
                                .sensoryFeedback(.impact(weight: .medium), trigger: selected?.id == g.id)
                        }
                    }
                    .padding(.horizontal, Brand.Spacing.xl)
                    .padding(.top, Brand.Spacing.l)
                    .padding(.bottom, Brand.Spacing.xxl * 2)
                }
                .refreshable { await app.refreshProfileAndGroups() }
                floatingButton
            }
            .navigationDestination(item: $selected) { g in GroupSummaryView(group: g) }
            .navigationDestination(isPresented: $showCreate) { NewGroupWizard() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.xs) {
            Text("Hola, \(app.profile?.displayName ?? "")")
                .font(.tandaTitle).foregroundStyle(.white.opacity(0.7))
            Text("Mis grupos")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var floatingButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    showCreate = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Nuevo")
                    }
                    .font(.tandaTitle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Brand.Spacing.l)
                    .padding(.vertical, Brand.Spacing.m)
                    .adaptiveGlass(Capsule(), tint: Brand.accent, interactive: true)
                }
                .padding(.trailing, Brand.Spacing.xl)
                .padding(.bottom, Brand.Spacing.xl)
            }
        }
    }
}

// Stub for task 17
struct GroupSummaryView: View {
    let group: Group
    var body: some View { Text("\(group.name) summary (stub)").foregroundStyle(.white) }
}
```

- [ ] **Step 3: Snapshot tests (empty + 3 groups)**

`ios/TandasTests/GroupsListViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("GroupsListView snapshots")
@MainActor
struct GroupsListViewSnapshotTests {
    @Test("with three groups")
    func threeGroups() async {
        let groups = [
            Group(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Cena martes", description: nil, groupType: .recurringDinner, inviteCode: "abc12345", createdAt: .now),
            Group(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Tanda viejos", description: nil, groupType: .tandaSavings, inviteCode: "def67890", createdAt: .now),
            Group(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Poker miércoles", description: nil, groupType: .poker, inviteCode: "pkr12345", createdAt: .now)
        ]
        let app = AppState(
            auth: MockAuthService(),
            profileRepo: MockProfileRepository(seed: Profile(id: UUID(), displayName: "Jose", avatarUrl: nil, phone: nil)),
            groupsRepo: MockGroupsRepository(seed: groups)
        )
        app.profile = Profile(id: UUID(), displayName: "Jose", avatarUrl: nil, phone: nil)
        app.groups = groups
        app.isBootstrapping = false
        let view = GroupsListView().environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 4: Remove stub, record, verify**

Remove `GroupsListView` stub from `TandasApp.swift`. Run record + verify.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Features/Groups/GroupsListView.swift \
        ios/Tandas/DesignSystem/Components/WalletGroupCard.swift \
        ios/TandasTests/GroupsListViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/ \
        ios/Tandas/TandasApp.swift
git commit -m "feat(ios): GroupsListView with WalletGroupCard + deterministic palette"
```

---

## Task 17: GroupSummaryView (placeholder for Phase 2 timeline)

**Files:**
- Create: `ios/Tandas/Features/Groups/GroupSummaryView.swift`
- Create: `ios/TandasTests/GroupSummaryViewSnapshotTests.swift`

- [ ] **Step 1: Implement `GroupSummaryView.swift`**

```swift
import SwiftUI

struct GroupSummaryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let group: Group

    @State private var members: [Member] = []
    @State private var isLeaving: Bool = false
    @State private var showLeaveConfirm: Bool = false
    @State private var copied: Int = 0

    var body: some View {
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(spacing: Brand.Spacing.xl) {
                    header
                    inviteCard
                    membersCard
                    leaveButton
                }
                .padding(.horizontal, Brand.Spacing.xl)
                .padding(.top, Brand.Spacing.xl)
                .padding(.bottom, Brand.Spacing.xxl * 2)
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMembers() }
        .sensoryFeedback(.success, trigger: copied)
        .confirmationDialog(
            "¿Salir de \(group.name)?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Salir del grupo", role: .destructive) { Task { await leave() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Vas a perder acceso al grupo. Puedes volver a unirte con el invite code.")
        }
    }

    private var header: some View {
        VStack(spacing: Brand.Spacing.xs) {
            Image(systemName: group.groupType.symbolName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Brand.accent)
            Text(group.groupType.displayName)
                .font(.tandaCaption).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    private var inviteCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                Text("Invite code").font(.tandaCaption).foregroundStyle(.white.opacity(0.6))
                HStack {
                    Text(group.inviteCode)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = group.inviteCode
                        copied &+= 1
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                            .font(.tandaBody)
                            .padding(.horizontal, Brand.Spacing.m)
                            .padding(.vertical, Brand.Spacing.s)
                            .adaptiveGlass(Capsule(), interactive: true)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                Text("Compártelo con quien quieras invitar al grupo.")
                    .font(.tandaCaption).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var membersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Brand.Spacing.m) {
                Text("Miembros (\(members.count))")
                    .font(.tandaTitle).foregroundStyle(.white)
                if members.isEmpty {
                    Text("Tú eres el primero del grupo.")
                        .font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                } else {
                    ForEach(members) { m in
                        Text(m.displayNameOverride ?? m.userId.uuidString.prefix(8).description)
                            .font(.tandaBody).foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var leaveButton: some View {
        Button {
            showLeaveConfirm = true
        } label: {
            Text(isLeaving ? "Saliendo…" : "Salir del grupo")
                .font(.tandaBody)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Brand.Spacing.m)
                .adaptiveGlass(Capsule())
        }
        .disabled(isLeaving)
    }

    private func loadMembers() async {
        members = (try? await app.groupsRepo.members(of: group.id)) ?? []
    }

    private func leave() async {
        isLeaving = true
        defer { isLeaving = false }
        try? await app.groupsRepo.leave(group.id)
        await app.refreshProfileAndGroups()
        dismiss()
    }
}
```

- [ ] **Step 2: Snapshot test**

`ios/TandasTests/GroupSummaryViewSnapshotTests.swift`:

```swift
import Testing
import SwiftUI
import SnapshotTesting
@testable import Tandas

@Suite("GroupSummaryView snapshots")
@MainActor
struct GroupSummaryViewSnapshotTests {
    @Test("default")
    func defaultState() async {
        let g = Group(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Cena martes", description: nil, groupType: .recurringDinner, inviteCode: "abc12345", createdAt: .now)
        let app = AppState(auth: MockAuthService(), profileRepo: MockProfileRepository(), groupsRepo: MockGroupsRepository(seed: [g]))
        let view = NavigationStack { GroupSummaryView(group: g) }.environment(app).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        assertSnapshot(of: host, as: .image(on: .iPhone15Pro), record: false)
    }
}
```

- [ ] **Step 3: Replace stub, record, verify**

Replace prior `GroupSummaryView` stub. Snapshot record + verify.

- [ ] **Step 4: Commit**

```bash
git add ios/Tandas/Features/Groups/GroupSummaryView.swift \
        ios/TandasTests/GroupSummaryViewSnapshotTests.swift \
        ios/TandasTests/__Snapshots__/
git commit -m "feat(ios): GroupSummaryView with copyable invite_code + leave confirm"
```

---

## Task 18: XCUITest happy path (E2E)

**Files:**
- Create: `ios/TandasUITests/HappyPathTests.swift`
- Modify: `ios/Tandas/TandasApp.swift` (add a `LAUNCH_ENV` flag to swap in mock services for UI tests)

- [ ] **Step 1: Add launch-env-driven mock toggle in `TandasApp`**

Modify `TandasApp.init()`:

```swift
init() {
    let useMocks = ProcessInfo.processInfo.environment["TANDAS_USE_MOCKS"] == "1"
    if useMocks {
        let auth = MockAuthService()
        let profile = MockProfileRepository(seed: Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil))
        let groups = MockGroupsRepository()
        _appState = State(initialValue: AppState(auth: auth, profileRepo: profile, groupsRepo: groups))
    } else {
        let client = SupabaseEnvironment.shared
        let auth = LiveAuthService(client: client)
        let profile = LiveProfileRepository(client: client)
        let groups = LiveGroupsRepository(client: client)
        _appState = State(initialValue: AppState(auth: auth, profileRepo: profile, groupsRepo: groups))
    }
}
```

- [ ] **Step 2: Write `HappyPathTests.swift`**

```swift
import XCTest

final class HappyPathTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFullOnboardingThroughCreatingGroup() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["TANDAS_USE_MOCKS": "1"]
        app.launch()

        // Login screen: pick Phone tab + dummy phone + send
        let phoneTab = app.segmentedControls.buttons["Teléfono"]
        XCTAssertTrue(phoneTab.waitForExistence(timeout: 5))
        phoneTab.tap()
        let phoneField = app.textFields.firstMatch
        phoneField.tap()
        phoneField.typeText("5215555550000")
        app.buttons["Enviarme código"].tap()

        // OTP input — type 123456 (mock-accepted)
        let otpField = app.textFields.firstMatch
        XCTAssertTrue(otpField.waitForExistence(timeout: 5))
        otpField.typeText("123456")

        // Onboarding — type display_name
        let nameField = app.textFields["Jose"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Jose Test")
        app.buttons["Continuar"].tap()

        // Empty groups → tap "Crear un grupo"
        XCTAssertTrue(app.buttons["Crear un grupo"].waitForExistence(timeout: 5))
        app.buttons["Crear un grupo"].tap()

        // Wizard step 1: tap "Cena recurrente"
        XCTAssertTrue(app.buttons["Cena recurrente"].waitForExistence(timeout: 5))
        app.buttons["Cena recurrente"].tap()

        // Step 2: type group name
        let groupNameField = app.textFields.firstMatch
        XCTAssertTrue(groupNameField.waitForExistence(timeout: 5))
        groupNameField.tap()
        groupNameField.typeText("Cena martes")
        app.buttons["Siguiente"].tap()

        // Step 3: defaults visible (recurring_dinner has step 3) → tap Crear grupo
        XCTAssertTrue(app.buttons["Crear grupo"].waitForExistence(timeout: 5))
        app.buttons["Crear grupo"].tap()

        // Welcome — tap "Entrar al grupo"
        XCTAssertTrue(app.buttons["Entrar al grupo"].waitForExistence(timeout: 5))
        app.buttons["Entrar al grupo"].tap()

        // Groups list shows the new group
        XCTAssertTrue(app.staticTexts["Cena martes"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 3: Run UI test**

```bash
cd ios && xcodebuild test \
  -project Tandas.xcodeproj \
  -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
  -only-testing:TandasUITests/HappyPathTests/testFullOnboardingThroughCreatingGroup
```

Expected: passes. The mock-backed flow goes login → OTP → onboarding → empty → wizard → welcome → list.

- [ ] **Step 4: Commit**

```bash
git add ios/TandasUITests/HappyPathTests.swift ios/Tandas/TandasApp.swift
git commit -m "test(ios): XCUITest happy path with TANDAS_USE_MOCKS=1 launch flag"
```

---

## Task 19: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ios-ci.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: iOS CI

on:
  push:
    branches: [main, ios-rewrite]
  pull_request:
    branches: [main, ios-rewrite]

jobs:
  build-test:
    runs-on: macos-15
    timeout-minutes: 30
    env:
      TANDAS_SUPABASE_URL: ${{ secrets.TANDAS_SUPABASE_URL }}
      TANDAS_SUPABASE_ANON_KEY: ${{ secrets.TANDAS_SUPABASE_ANON_KEY }}
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app

      - name: Install xcodegen
        run: brew install xcodegen

      - name: Write local xcconfig from secrets
        run: |
          cat > ios/Tandas.local.xcconfig <<EOF
          TANDAS_SUPABASE_URL = ${TANDAS_SUPABASE_URL/\/\//\/$()\/}
          TANDAS_SUPABASE_ANON_KEY = $TANDAS_SUPABASE_ANON_KEY
          EOF

      - name: Generate project
        run: cd ios && xcodegen

      - name: Build
        run: |
          xcodebuild build \
            -project ios/Tandas.xcodeproj \
            -scheme Tandas \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
            CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
            | xcpretty
          exit ${PIPESTATUS[0]}

      - name: Test (unit + snapshot + UI)
        run: |
          xcodebuild test \
            -project ios/Tandas.xcodeproj \
            -scheme Tandas \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
            CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
            | xcpretty
          exit ${PIPESTATUS[0]}
```

- [ ] **Step 2: Document required GitHub secrets with user**

Tell the user to add to repo Settings → Secrets and variables → Actions:
- `TANDAS_SUPABASE_URL` = `https://fpfvlrwcskhgsjuhrjpz.supabase.co`
- `TANDAS_SUPABASE_ANON_KEY` = the anon key

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ios-ci.yml
git commit -m "ci(ios): GitHub Actions workflow for build + test on macos-15"
```

---

## Task 20: TestFlight build #1

**Files:**
- (no code changes — process steps for the user)

- [ ] **Step 1: Confirm Apple Developer prereqs (user)**

User confirms:
1. Apple Developer account active under personal team.
2. App ID `com.josejmizrahi.tandas` registered with `Sign in with Apple` capability enabled.
3. Provisioning profile created (Xcode Automatic signing usually handles this).

- [ ] **Step 2: Bump build number in `project.yml`**

Edit `ios/project.yml`, change:

```yaml
    CURRENT_PROJECT_VERSION: "2"  # was "1"
```

Regenerate:

```bash
cd ios && make project
```

- [ ] **Step 3: Archive (user, in Xcode)**

User opens `ios/Tandas.xcodeproj` in Xcode 16+, selects:
- Scheme: Tandas
- Destination: Any iOS Device (arm64)
- Product → Archive

Wait ~2-5 min. Organizer opens with the archive.

- [ ] **Step 4: Distribute to App Store Connect (TestFlight)**

In Organizer:
- Click Distribute App
- Choose "App Store Connect" → "Upload"
- Use Automatic signing
- Upload completes in 5-10 min

App Store Connect processes the build (10-30 min), then it's available in TestFlight Internal Testing.

- [ ] **Step 5: Install on device (user)**

User opens TestFlight on their iPhone with iOS 26+, accepts invite, installs Tandas, runs through happy path.

- [ ] **Step 6: Smoke checklist on device**

User confirms:
- [ ] Sign in with Apple works (FaceID prompt → app)
- [ ] Phone OTP receives real SMS to user's phone
- [ ] Email OTP receives real email
- [ ] Onboarding writes display_name in `profiles` (verify via Supabase dashboard)
- [ ] Crear grupo writes row in `public.groups` with `group_type = recurring_dinner`
- [ ] Joinear con código (use the `invite_code` from above) adds user to `group_members`
- [ ] WalletGroupCard shows the group with deterministic color
- [ ] Tap card → invite_code copy works
- [ ] Salir del grupo flips `active = false` in `group_members`
- [ ] No crashes when toggling Reduce Transparency in Settings → Accessibility

- [ ] **Step 7: Bump version + commit version bump**

```bash
git add ios/project.yml
git commit -m "chore(ios): bump build to 2 for TestFlight #1"
```

- [ ] **Step 8: Tag the release**

```bash
git tag ios-phase-1-testflight-1
git push origin ios-rewrite --tags
```

---

## Self-Review

**Spec coverage:**
- §1 Overview, §2 Decisions Log → captured implicitly across tasks (deployment, auth methods, scaffold) — ✓
- §3 Architecture (stack, layout, boundaries, data flow, auth flow, errors) → tasks 1, 3, 5, 6, 7, 8 — ✓
- §4 Visual System (.adaptiveGlass, tokens, typography, components) → task 4 — ✓
- §5 Phase 1 Screens (9 pantallas) → tasks 9 (LoginView), 10 (OTPInputView), 11 (OnboardingView), 12 (EmptyGroupsView), 13 (JoinByCodeView), 14 (NewGroupWizard), 15 (WelcomeView), 16 (GroupsListView), 17 (GroupSummaryView) — ✓
- §6 Backend changes (migration 00010 + repo cleanup + .gitignore) → tasks 1 (cleanup) + 2 (migration) — ✓
- §7 Testing (unit/integration/snapshot/E2E) → tasks 4-17 (snapshot per view) + 18 (XCUITest) — ✓
- §8 Acceptance criteria → all checkable against tasks 1-20 — ✓
- §9 Signing & capabilities → tasks 1 (entitlements), 20 (TestFlight) — ✓

**Placeholder scan:** No "TBD"/"TODO"/"add appropriate" — code blocks are concrete. Snapshot recording explicitly requires manual review the first time, which is acknowledged.

**Type consistency:** `AuthService` protocol, `Profile`, `Group`, `GroupType`, `CreateGroupParams`, `Member`, `GroupDetail`, `OTPChannel`, `AuthMethod`, `AppSession`, `AppUser`, `AppState` — names consistent across tasks 4–18. `MockAuthService.signInWithApple()` returns a synthetic session (mock convention); `LiveAuthService.signInWithApple(idToken:nonce:)` is the actual entry point used by `LoginView`. Both implement the protocol; the divergence is intentional (mock satisfies protocol with throws-not-needed default, live exposes the extra method only on the concrete actor type — `LoginView` uses `as? LiveAuthService` to opt in).

**No outstanding gaps.**

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-30-tandas-ios-phase-1-implementation.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for the 20 tasks here because each is self-contained with verifiable build/test gates.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

Which approach?
