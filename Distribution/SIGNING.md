# Signing, notarizing & sharing WhiskerFlow

WhiskerFlow is distributed outside the App Store, so for it to open **without
Gatekeeper warnings** on a teammate's Mac it must be:

1. signed with a **Developer ID Application** certificate,
2. **notarized** by Apple, and
3. have the notarization ticket **stapled** to the app and the DMG.

`script/notarize.sh` does all three in one command. This is a one-time setup,
then each release is a single command.

---

## One-time setup

### 1. Create a "Developer ID Application" certificate

Your keychain likely only has an *Apple Development* certificate, which **cannot**
be notarized. Create the Developer ID one (needs the Account Holder/Admin role on
the Apple Developer team):

- **Xcode** → Settings → Accounts → select your team → **Manage Certificates** →
  click **+** → **Developer ID Application**.

Verify it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Store notarization credentials in a keychain profile

Use an **app-specific password** (appleid.apple.com → Sign-In & Security →
App-Specific Passwords), then:

```bash
xcrun notarytool store-credentials "WhiskerFlow-Notary" \
  --apple-id "you@example.com" \
  --team-id  "DR37YKTXWX" \
  --password "abcd-efgh-ijkl-mnop"
```

(Or an App Store Connect API key: `--key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>`.)

The profile name `WhiskerFlow-Notary` is what `notarize.sh` expects (override with
`NOTARY_PROFILE`).

---

## Cut a release

```bash
VERSION=0.3.0 script/notarize.sh
```

This will:

1. build a **release** binary and sign it (hardened runtime + `Resources/WhiskerFlow.entitlements`),
2. notarize the app and staple its ticket,
3. build `dist/WhiskerFlow-<version>.dmg`, notarize and staple it,
4. verify Gatekeeper acceptance, and
5. update `Casks/whiskerflow.rb` with the new version and the DMG's real `sha256`.

Then publish the DMG and commit the cask:

```bash
gh release create "v0.3.0" "dist/WhiskerFlow-0.3.0.dmg" \
  --title "WhiskerFlow 0.3.0" --notes "Live transcription release"
git commit -am "release: WhiskerFlow 0.3.0" && git push
```

> The tag-triggered GitHub Actions workflow (`.github/workflows/release.yml`)
> builds only an **ad-hoc** (unsigned) DMG — it has no signing certificate. Share
> the DMG produced by `notarize.sh`, not the CI one, or wire signing secrets into
> CI later.

---

## Team install (Homebrew Cask)

Once the release is published and the cask is pushed to `main`:

```bash
brew install --cask "https://raw.githubusercontent.com/jw29247/WhiskerFlow/main/Casks/whiskerflow.rb"
```

Upgrades use the same command after you publish a new version. (This assumes the
repo is public so Homebrew can fetch the cask and the DMG; for a private repo,
distribute the notarized DMG directly or set up an authenticated tap.)

First launch still asks the user to grant **Microphone** and **Accessibility**
permissions in System Settings → Privacy & Security — that's expected and
unrelated to signing.
