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
  --team-id  "G9U38P58ZY" \
  --password "abcd-efgh-ijkl-mnop"
```

(Or an App Store Connect API key: `--key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>`.)

The profile name `WhiskerFlow-Notary` is what `notarize.sh` expects (override with
`NOTARY_PROFILE`).

### 3. Generate the Sparkle auto-update signing key (one-time)

Auto-updates are EdDSA-signed. Generate the key once — the **private** key stays
in your login Keychain, and the **public** key is written into `Info.plist`:

```bash
script/sparkle_keygen.sh        # sets SUPublicEDKey in Resources/Info.plist
```

Commit the updated `Info.plist`, and **back up the private key** somewhere safe
(losing it means you can't ship updates that existing installs will accept):

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
# store that file securely — NOT in git
```

`notarize.sh` refuses to build until `SUPublicEDKey` is set.

---

## Cut a release

Bump `CFBundleShortVersionString` **and** `CFBundleVersion` in
`Resources/Info.plist` first (Sparkle compares `CFBundleVersion`, so it must
increase every release), then:

```bash
VERSION=0.4.0 script/notarize.sh        # optional: NOTES="One-line changelog"
```

This will:

1. build a **release** binary, embed + sign `Sparkle.framework`, and Developer-ID
   sign the app (hardened runtime + `Resources/WhiskerFlow.entitlements`),
2. notarize the app and staple its ticket,
3. build `dist/WhiskerFlow-<version>.dmg`, notarize and staple it,
4. zip the notarized app to `dist/WhiskerFlow-<version>.zip` (the Sparkle update
   archive) and add a signed entry to `appcast.xml`,
5. verify Gatekeeper acceptance, and
6. update `Casks/whiskerflow.rb` with the new version and the DMG's real `sha256`.

Then publish **both** assets (the appcast points at the `.zip`) and commit the
appcast + cask so they go live on `main`:

```bash
gh release create "v0.4.0" "dist/WhiskerFlow-0.4.0.dmg" "dist/WhiskerFlow-0.4.0.zip" \
  --title "WhiskerFlow 0.4.0" --notes "What changed…"
git commit -am "release: WhiskerFlow 0.4.0" && git push   # ships appcast.xml + cask
```

> The tag-triggered GitHub Actions workflow (`.github/workflows/release.yml`)
> builds only an **ad-hoc** (unsigned) DMG — it has no signing certificate. Share
> the DMG produced by `notarize.sh`, not the CI one, or wire signing secrets into
> CI later.

---

## Team install & auto-updates

The repo is **public** so Sparkle and Homebrew can fetch `appcast.xml`, the cask,
and the release binaries without authentication.

**First install** (or anyone still on ≤ 0.3.0, which predates auto-update):

```bash
brew install --cask "https://raw.githubusercontent.com/jw29247/WhiskerFlow/main/Casks/whiskerflow.rb"
```

**After that, updates are automatic.** Every build from 0.4.0 onward embeds
Sparkle, checks `appcast.xml` daily (and via *Check for Updates…* in the menu-bar
menu / app menu / Settings → Updates), and installs new signed releases in place.
Teammates only need the one-time install above to get on the auto-update track.

First launch still asks the user to grant **Microphone** and **Accessibility**
permissions in System Settings → Privacy & Security — that's expected and
unrelated to signing.
