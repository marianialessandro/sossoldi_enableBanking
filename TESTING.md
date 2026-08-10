# Testing the Enable Banking feature (issue #481)

This is a practical checklist to verify the bank-sync feature actually works,
not just that it compiles. It covers the automated checks (fast, no bank
account needed) and the manual end-to-end walkthrough (needs a real Enable
Banking **sandbox** application — see
[`docs/setup/enable-banking.md`](docs/setup/enable-banking.md) for how to get
one).

Do the automated pass first — it catches most regressions in seconds and
tells you whether it's even worth booting a simulator.

## 0. Automated checks (no device, no sandbox needed)

```sh
fvm flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart format --set-exit-if-changed --output=none .
flutter analyze
flutter test --concurrency=1
```

All five must be clean/green — this is the exact sequence the CI runs
(`.github/workflows/ci-cd.yml`, job `format-test-build`). Use
`--concurrency=1`: the default concurrency can show spurious failures from
shared sqflite state between test files that don't happen in CI.

If you only want to re-check the banking code specifically:

```sh
flutter test --concurrency=1 \
  test/services/banking/ \
  test/model/bank_account_test.dart \
  test/model/bank_connection_test.dart \
  test/model/transaction_test.dart \
  test/services/database/migrations/add_bank_sync_test.dart \
  test/providers/banking_provider_test.dart \
  test/widget/enable_banking_setup_page_test.dart \
  test/widget/connect_bank_page_test.dart \
  test/widget/import_accounts_page_test.dart
```

This exercises: JWT signing (`enable_banking_auth_test.dart`), the REST
client against a mocked HTTP transport (`enable_banking_api_test.dart`), the
credentials store, the deep-link parser, the DTO parsing (`eb_models_test`),
the DB migration, the model/repository CRUD (including transaction dedup),
the Riverpod flow (`ConnectBankFlow`/`BankCallbackHandler`), the transaction
mapper and the sync service (pagination, dedup on re-sync, 401 → `EXPIRED`),
and the three key screens. None of it needs a real Enable Banking account —
everything is mocked or runs against an in-memory sqlite DB.

**What automated tests can't tell you**, and the rest of this document
covers: whether the real OAuth round trip to a bank actually works, whether
the deep link reopens the app on a real device/simulator, whether the UI
looks right in light/dark, and whether a real sandbox bank's data maps
correctly (remittance info, dates, pending vs booked transactions vary by
ASPSP).

## 1. One-time setup: a sandbox Enable Banking application

Full instructions: [`docs/setup/enable-banking.md`](docs/setup/enable-banking.md).
Short version:

1. Register an application at
   [enablebanking.com/cp/applications](https://enablebanking.com/cp/applications)
   choosing the **sandbox** environment (not production — sandbox gives you
   fake test banks you can complete consent on without a real bank account).
2. Generate the RSA key pair, upload the certificate, note the `app_id`.
3. Register the redirect URI `sossoldi://eb-callback`.

Keep the `app_id` and the private key PEM file handy — you'll paste/import
them into the app in step 3 below.

## 2. Run the app

```sh
fvm flutter run -d <device>
```

Use a real device or simulator/emulator, not a headless test — the OAuth
consent step opens an external browser and needs the deep link to bounce
back into a running app.

## 3. Configure credentials — `Settings → Bank sync`

- [ ] Open Settings, tap **Bank sync**. Without credentials yet, no "Linked
      banks" card and no "Credentials configured" banner should show.
- [ ] Enter the sandbox `app_id`.
- [ ] Paste the private key PEM, or tap the import icon and pick the
      `.pem`/`.key` file. Confirm the file picker works (Android ≤ 12 needs
      storage permission — check that prompt appears once).
- [ ] Toggle **"Use sandbox"** on (this is informational only, it does not
      change which API host is called — see the setup guide).
- [ ] Tap **SAVE CREDENTIALS**. Expect a "Credentials saved" confirmation,
      and the screen to now show a "Credentials configured" banner plus a
      **"Linked banks"** card.
- [ ] **Negative case**: clear the PEM field, paste garbage instead of a
      real key, save → expect an "Invalid private key" error, nothing
      persisted.
- [ ] **Negative case**: leave `app_id` empty, save → expect a validation
      error, no crash.
- [ ] Reopen the page: the PEM field should show a `•••• configured`
      hint, not the real key (it's never re-read from secure storage for
      display).
- [ ] Tap the copy icon next to **Redirect URI** → expect a "Copied"
      snackbar and `sossoldi://eb-callback` on the clipboard.
- [ ] **Clear credentials**: tap the destructive "Clear credentials"
      button, confirm the dialog → expect the "Credentials configured"
      banner and "Linked banks" card to disappear. Re-enter credentials
      before continuing to the next section.

## 4. Deep link sanity check (before doing a real OAuth round trip)

This isolates "does the callback plumbing work at all" from "does the whole
OAuth flow work", which is useful if step 5 below fails and you need to
narrow down where.

Android:

```sh
adb shell am start -a android.intent.action.VIEW \
  -d "sossoldi://eb-callback?code=test&state=test"
```

iOS simulator:

```sh
xcrun simctl openurl booted "sossoldi://eb-callback?code=test&state=test"
```

- [ ] With the app in the foreground, background, and cold-started (killed),
      firing the URI brings the app to the foreground.
- [ ] Since `state=test` won't match any real in-progress flow's CSRF token,
      expect the app to surface "No bank connection in progress, please
      start again" (via a snackbar) rather than crash.
- [ ] `sossoldi://eb-callback?error=access_denied` → expect that error
      message surfaced instead.

## 5. Connect a bank — `Linked banks` (`/connect-bank`)

- [ ] From **Bank sync**, tap the **Linked banks** card (or navigate to
      `/connect-bank` directly). With no connections yet, expect the empty
      state: "No banks linked yet" / "Tap + to link your first bank".
- [ ] Tap the **+** icon in the app bar → country picker bottom sheet opens.
- [ ] Pick a country your sandbox application supports → bank (ASPSP)
      picker bottom sheet opens, populated from a real `GET /aspsps` call.
      If it's empty or errors, check the sandbox app_id/credentials and
      that the chosen country actually has sandbox ASPSPs registered for
      your application.
- [ ] Pick a bank → the app calls `POST /auth` and opens the consent URL in
      an **external browser**. While this is in flight, the **+** icon in
      the app bar should show a small spinner instead of the icon.
- [ ] Complete the sandbox bank's consent flow in the browser (sandbox
      banks typically accept any test credentials — check Enable Banking's
      sandbox docs for the specific mock bank's login if it's not obvious).
- [ ] The browser redirects to `sossoldi://eb-callback?...` → the app
      should come back to the foreground and land on **Import accounts**.
- [ ] **Negative case**: on the bank's consent page, deny/cancel instead of
      approving → expect the app to surface an error (via snackbar) rather
      than getting stuck, and no connection gets created.

## 6. Import accounts — `Import accounts` (`/import-accounts`)

- [ ] The page lists every account the session returned, with a header like
      "Select the accounts to import".
- [ ] Each account shows a masked IBAN (e.g. `IT•• ••56`) and, if the
      balance call succeeds, a balance; a failed/missing balance must not
      block anything — it should just default to 0, not show an error.
- [ ] Toggle an account off — its name/icon/color fields should disappear;
      the footer **IMPORT SELECTED** button should disable when nothing is
      selected.
- [ ] For at least one account, edit the name and change icon/color via the
      picker (same widget as manual accounts — compare against
      `Accounts → + → create account` for a visual gut-check).
- [ ] Tap **IMPORT SELECTED** → expect a snackbar like "N accounts
      imported" and to land back on **Linked banks**, now showing a
      connection card for the bank you just linked.
- [ ] Go to the main **Accounts** list and the **Dashboard**: the imported
      account(s) should appear there, indistinguishable in style from
      manual accounts, with the IBAN/name/icon/color you set.

## 7. Sync transactions

- [ ] On the connection card (**Linked banks**), tap the refresh icon.
      Expect a spinner while syncing, then a snackbar "Synced N
      transactions".
- [ ] Open the imported account / the main **Transactions** list: the
      synced transactions should appear with correct amount, sign
      (income vs expense), date and a note (from remittance info /
      creditor-debtor name — check a few against what the sandbox bank
      actually returned, since exact fields vary by ASPSP).
- [ ] Tap refresh again immediately → expect "Synced 0 transactions" (no
      duplicates). Check the transaction count in the list didn't change.
- [ ] The connection card's "Last synced" label should update to "today"
      after a successful sync.
- [ ] **Daily auto-sync**: on a fresh app start (not just hot reload),
      `lib/main.dart` runs a background sync gated to once/day via the
      `last_bank_sync_check` key in shared preferences. To force it to run
      again without waiting a day, uninstall/reinstall the app (or clear
      app storage) before this specific check — this resets the gate along
      with all local data, so only do it as a dedicated pass, not mixed
      into the rest of this checklist. This path is covered by
      `_maybeSyncBankConnections` at the unit level; manually confirming it
      fires is optional but worth doing once.

## 8. Expired consent and disconnect

- [ ] If your sandbox lets you revoke a consent from the bank's/Enable
      Banking's side, do so, then tap refresh on the connection card →
      expect the card to flip to an **EXPIRED** badge with a full-width
      **RECONNECT** button instead of the sync/disconnect row.
- [ ] Tap **RECONNECT** → same consent flow as step 5; on success the
      connection should go back to active.
- [ ] Tap the disconnect icon (link-off) on an active connection → confirm
      the destructive dialog → expect a "Bank disconnected" snackbar, the
      connection card removed from **Linked banks**, and the accounts it
      fed turned back into **manual** accounts (still present, in the
      Accounts list, with their transaction history intact — just no
      longer linked/synced).

## 9. Visual check

- [ ] Toggle the device to dark mode and repeat a quick pass over: Bank
      sync, Linked banks (with at least one connection), country/ASPSP
      bottom sheets, Import accounts, the icon/color picker. Nothing
      should look out of place compared to the equivalent manual-account
      screens (`create_edit_account_page`, `account_list_page`).

## 10. Platform coverage

The deep link and secure storage wiring differs per platform — if you can,
repeat at least steps 4 and 5 on more than one of:

- [ ] Android (physical device or emulator)
- [ ] iOS (simulator is fine for the deep link; consent still needs a real
      browser round trip)
- [ ] macOS (desktop build — check `CFBundleURLTypes` in
      `macos/Runner/Info.plist` is picked up)

## 11. Optional: the existing integration test

`integration_test/banking_test.dart` drives the setup/connect-bank screens
with a **throwaway, unregistered** key pair (`_testPem` in that file) — it
deliberately does not have a real Enable Banking application, so it stops
right after picking a bank in the ASPSP sheet, asserting that the API
failure is *reported* rather than *hanging*. It's a good regression check
for the setup/connect-bank screens (including a dark-mode pass) but it does
**not** exercise a real OAuth round trip, import, or sync — steps 5–8 above
still have to be done by hand with real sandbox credentials.

Two things worth knowing before running it:

- It still makes a real network call to `https://api.enablebanking.com`
  with the fake `app_id` (expected to fail with a 4xx) — it is not fully
  offline.
- Its `shot()` helper only prints a `SHOT <name>` marker and pauses; the
  actual screenshot capture (`xcrun simctl io screenshot`) is external and
  keyed off that marker, it's not wired through `test_driver/`'s
  `onScreenshot` callback for this test. On Android, or if you don't need
  screenshots, just run it directly:

```sh
flutter test integration_test/banking_test.dart -d <device>
```

## Known-safe to skip

- The `flutter build apk`/App Bundle CI steps ("Dump keystore" / "Create
  key.properties") depend on secrets not available locally — irrelevant to
  functional testing, see `CLAUDE.md`.
