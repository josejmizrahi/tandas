# `.well-known/` for ruul.mx

Static files that MUST be served as-is at `https://ruul.mx/.well-known/<file>`.

## `apple-app-site-association`

Apple Universal Links manifest. Tells iOS which URL paths on `ruul.mx`
should open the Ruul native app instead of Safari.

**Critical serving requirements** (Apple docs, App Search Programming Guide):

1. **HTTPS only** (no plaintext fallback). `ruul.mx` must have a valid TLS cert.
2. **Content-Type: `application/json`** in the response headers.
3. **No redirects.** If `https://ruul.mx/.well-known/apple-app-site-association`
   returns 30x, iOS gives up. Serve the JSON directly at that exact URL.
4. **No file extension** in the path. The file is literally named
   `apple-app-site-association` (no `.json`).
5. **Cache-Control: `max-age=300`** or shorter while iterating; Apple's CDN
   caches the AASA aggressively otherwise.

## Vercel hosting recipe

If `ruul.mx` is hosted on Vercel, place this directory as `public/.well-known/`
in the web project root and add the following to `vercel.json`:

```json
{
  "headers": [
    {
      "source": "/.well-known/apple-app-site-association",
      "headers": [
        { "key": "Content-Type", "value": "application/json" },
        { "key": "Cache-Control", "value": "max-age=300" }
      ]
    }
  ]
}
```

Vercel serves files in `public/` at the site root by default. No further
config needed.

## Other hosts

- **Netlify**: place at `public/.well-known/` and add `_headers`:
  ```
  /.well-known/apple-app-site-association
    Content-Type: application/json
    Cache-Control: max-age=300
  ```
- **Cloudflare Pages**: same as Netlify (uses the same `_headers` syntax).
- **NGINX**: add to your server block:
  ```nginx
  location = /.well-known/apple-app-site-association {
      default_type application/json;
      add_header Cache-Control "max-age=300";
  }
  ```
- **S3 + CloudFront**: upload the file with `Content-Type: application/json`
  metadata; add a CloudFront behavior for `/.well-known/*` that strips
  caching headers and forwards as-is.

## Verifying

After deploy, run from any machine with internet:

```bash
curl -sS -H "Accept: application/json" \
  https://ruul.mx/.well-known/apple-app-site-association | jq .
```

You should see the JSON pretty-printed. If you see HTML, Vercel/your host
is serving the SPA fallback — check the route config.

Then validate against Apple's CDN (which is what your phone actually hits):

```bash
curl -sS "https://app-site-association.cdn-apple.com/a/v1/ruul.mx" | jq .
```

Apple's CDN refreshes from your origin every few hours; if this returns
stale data, just wait. You can also force a refresh via the App Search
API but it's rarely necessary.

## Final iOS-side check

1. Build + install the app on a real device (Simulator does not exercise
   Universal Links — only deep-link schemes).
2. Sign in.
3. From WhatsApp (or any messaging app), tap a link like
   `https://ruul.mx/claim/abc123` — it should open Ruul directly and
   land on `ClaimReviewView`.
4. If it opens Safari instead, the AASA is unreachable or malformed.
   Long-press the link → "Open in Ruul" should appear when Universal
   Links is correctly configured.
