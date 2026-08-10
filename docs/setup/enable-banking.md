---
title: Enable Banking Setup Guide
layout: default
nav_order: 6
parent: Setup Guide
---

# Enable Banking (PSD2) Setup Guide

Sossoldi can link real bank accounts and import their transactions through
[Enable Banking](https://enablebanking.com/), a PSD2 open-banking aggregator.

Sossoldi is local-first and ships without a backend (it's also distributed on
F-Droid), so it can't hold a shared API key for every user. Instead it uses a
**BYOC (Bring Your Own Credentials)** model: each user (or each contributor
testing the feature) registers their own Enable Banking application and
enters its credentials in the app. Every API request is signed **on-device**
with an RS256 JWT built from those credentials; the private key never leaves
the device and is never committed to this repository.

This guide walks through registering an Enable Banking application and
configuring Sossoldi to use it. It's needed both by real users who want to
link their bank and by contributors who want to exercise the bank-sync code
paths locally (most of the banking logic is unit-testable without this setup
— see `test/services/banking/` — but the end-to-end connect/import/sync flow
needs a real application).

## 1. Register an application

1. Go to the [Enable Banking control panel](https://enablebanking.com/cp/applications)
   and sign up / log in.
2. Create a new application. Enable Banking asks you to choose an environment
   (**sandbox** for testing against fake banks, **production** for real
   ones) — this choice is fixed for the application's lifetime, it can't be
   switched later from within Sossoldi (see [Sandbox vs production](#4-sandbox-vs-production)
   below).

## 2. Generate an RSA key pair and certificate

Enable Banking identifies your application by a certificate, not a plain API
key. You need a 4096-bit RSA key pair and a self-signed certificate built
from it.

**If you're doing this from your phone** (the common case for a real user),
let Sossoldi generate it for you, entirely on-device:

1. Open **Settings → Bank sync** (`/enable-banking-setup`) in Sossoldi.
2. Tap **"Generate new key & certificate"**. Sossoldi creates the key pair
   and a self-signed certificate on-device; this can take up to a minute
   (RSA generation in pure Dart is slow by design — it's not stuck). The
   private key goes straight to secure storage (Keychain on iOS/macOS,
   Keystore-backed encrypted storage on Android) and is never shown or
   exported — you can't lose it by fumbling a copy/paste.
3. Pick a folder to save the certificate it offers
   (`enablebanking-certificate.pem`). You'll upload this file to the Enable
   Banking control panel in the next step.

**If you're doing this from a computer** (typical for contributors), you can
generate it yourself instead, for example with `openssl`:

```sh
openssl genrsa -out enablebanking-private-key.pem 4096
openssl req -new -x509 -key enablebanking-private-key.pem \
  -out enablebanking-certificate.pem -days 730
```

Keep `enablebanking-private-key.pem` private — it's the file you'll paste
(or import) into Sossoldi in step 5.

Either way:

- Upload the certificate (`enablebanking-certificate.pem`) to the
  application in the Enable Banking control panel. Follow their current
  instructions for the exact upload step, since the control panel UI can
  change.
- Once the certificate is accepted, the control panel shows your
  application's **`app_id`**. You'll need it in step 5.

## 3. Register the redirect URI

Enable Banking redirects the user back to Sossoldi after they grant consent
at their bank. Sossoldi listens for this via
[`app_links`](https://pub.dev/packages/app_links) on Android, iOS and macOS
(see `AndroidManifest.xml`'s intent filter and the `CFBundleURLTypes` entries
in the iOS/macOS `Info.plist`s), via the custom URI scheme:

```
sossoldi://eb-callback
```

Try registering that exact value first in the application's settings on the
Enable Banking control panel — it works for some sandbox applications.

**If the control panel rejects it** with an error like `URL uses unsupported
scheme` (this is the common case for **production** applications — custom
schemes aren't accepted there), you need an HTTPS URL you control that
bounces the browser back to the custom scheme:

1. Host a small static page at an HTTPS URL you control, for example
   `https://yourdomain.example/sossoldi/eb-callback.html`, with this content:

   ```html
   <!DOCTYPE html>
   <html>
   <body>
     <p>Returning to Sossoldi… <a id="fallback" href="#">tap here</a> if
       nothing happens.</p>
     <script>
       var target = 'sossoldi://eb-callback' + window.location.search;
       document.getElementById('fallback').href = target;
       window.location.replace(target);
     </script>
   </body>
   </html>
   ```

   It just relays the query string (`?code=...&state=...` or
   `?error=...`) Enable Banking attaches onto the custom scheme, so it works
   without any server-side logic — any static host (your own domain, GitHub
   Pages, Netlify, etc.) is enough.
2. Register that HTTPS URL as the redirect URL on the Enable Banking control
   panel instead.
3. Enter the same HTTPS URL in Sossoldi's **REDIRECT URI** field (Settings →
   Bank sync — see [step 5](#5-enter-the-credentials-in-sossoldi)); Sossoldi
   sends whatever you put there to Enable Banking on each authorization
   request. The default value is the custom scheme itself, which only works
   when the control panel accepted it in step 3 above.

## 4. Sandbox vs production

Enable Banking serves the same API host (`api.enablebanking.com`) for both
environments — which one you get is decided when the application is
registered (step 1), not per request. The **"Use sandbox"** switch in
Sossoldi's setup screen only records which environment you registered for,
for your own reference; it doesn't change what Sossoldi calls. If you need
both, register two separate applications and switch credentials between
them.

## 5. Enter the credentials in Sossoldi

1. Open **Settings → Bank sync** (`/enable-banking-setup`).
2. Enter the application's **`app_id`**.
3. If you generated the key in-app in step 2, leave the **private key
   PEM** field empty — Sossoldi already has it in secure storage and
   reuses it. Otherwise, paste the **private key PEM**, or use the import
   button to pick the `enablebanking-private-key.pem` file generated in
   step 2.
4. Set the **"Use sandbox"** switch to match how you registered the
   application (see [above](#4-sandbox-vs-production)).
5. The **redirect URI** field defaults to `sossoldi://eb-callback` and must
   match exactly what you registered in step 3 — edit it if you had to
   register an HTTPS bounce URL instead (see step 3's production note).
6. Save. Sossoldi confirms with "Credentials saved", and the screen now
   shows a "Credentials configured" banner.

## 6. Link a bank

From the same screen, open **Linked banks** (or `/connect-bank`), tap the
`+` action, pick a country and a bank. Sossoldi opens the bank's consent
page in an external browser; once you approve, you're redirected back to
Sossoldi to pick which of the bank's accounts to import.

Linked accounts sync automatically once a day (see
`lib/main.dart`'s `_maybeSyncBankConnections`), or on demand via the refresh
button on the connection's card in **Linked banks**.

## Troubleshooting

- **"Invalid private key"** when saving credentials: the pasted/imported PEM
  couldn't be parsed. Make sure you copied the whole
  `-----BEGIN PRIVATE KEY-----` ... `-----END PRIVATE KEY-----` block from
  `enablebanking-private-key.pem`, including both marker lines.
- **A linked bank shows "EXPIRED"**: the consent granted at the bank expired
  or was revoked on their side. Tap "RECONNECT" to go through the consent
  flow again; the already-imported accounts and their history are kept.
- **The redirect doesn't reopen Sossoldi**: double-check the redirect URI
  registered in the Enable Banking control panel is exactly
  `sossoldi://eb-callback`, with no trailing slash or typo.
