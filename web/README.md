# ruul.mx — landing + Universal Links

Static landing for `ruul.mx`. Designed to deploy on **Cloudflare Pages**
(point the project at this repo + select `web/public` as the output
directory; no build command needed). The same files work on Netlify or
any host that respects the `_headers` / `_redirects` Netlify-style
conventions.

## What it serves

```
/                                          → index.html (marketing splash)
/invite/<CODE>                             → dynamic invite landing
/.well-known/apple-app-site-association    → AASA for iOS Universal Links
/legal/terms                               → (todo) terms
/legal/privacy                             → (todo) privacy
```

## Apple Universal Links

The iOS app declares `applinks:ruul.mx` in entitlements + handles the
URL in `RuulAppShell.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`
→ `DeepLinkRouter` → `AcceptInviteSheet(prefilledCode:)`.

The AASA file at `/.well-known/apple-app-site-association` carries:

- `appIDs`: `G3TMTFSG7S.com.josejmizrahi.ruul` (TeamID.bundleID).
- `components`: `/invite/*` and `/group/*`.

iOS fetches AASA on app install — to refresh during testing, force a
re-install. The `apple-app-site-association` filename must NOT have an
extension and MUST be served as `application/json`.

## Deploying to Cloudflare Pages

1. Create a new Pages project, connect to this repo.
2. Build settings:
   - Build command: *(leave empty — static)*
   - Build output directory: `web/public`
3. Custom domain: add `ruul.mx` (Cloudflare DNS auto-binds).
4. Verify AASA:
   ```
   curl -I https://ruul.mx/.well-known/apple-app-site-association
   # Should respond 200 with Content-Type: application/json
   ```
5. Verify invite landing:
   ```
   open https://ruul.mx/invite/ABCD1234
   ```

## Replacing `app-id=PENDING`

When the app ships to TestFlight / App Store, replace `PENDING` in
`public/invite/[code].html` (`apple-itunes-app` meta) with the real
numeric app ID assigned by Apple. Until then the smart banner is a
no-op but doesn't break the page.
