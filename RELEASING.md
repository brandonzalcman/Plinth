# Releasing Plinth

Plinth ships as a signed, notarized `Plinth.dmg` on GitHub Releases. Installed copies update themselves with [Sparkle](https://sparkle-project.org), so people download the app once and get every later version automatically.

- **Landing page download link** (always the newest version):
  `https://github.com/brandonzalcman/Plinth/releases/latest/download/Plinth.dmg`
- **Update feed** that the app checks (built into `Scripts/Info.plist`):
  `https://github.com/brandonzalcman/Plinth/releases/latest/download/appcast.xml`

## How updates reach people

1. You merge a pull request into `main` that raises `MARKETING_VERSION` in `Plinth.xcodeproj` (and, ideally, adds `release-notes/<version>.md`). Merges that keep the same version do nothing: the workflow sees the release already exists and stops. (Pushing a tag such as `v0.2.0`, or running the workflow by hand, still works too.)
2. The **Release** workflow builds the app, signs it with your Developer ID, notarizes it with Apple and builds the DMG. It also writes `appcast.xml`, signed with your Sparkle key, and publishes both as a GitHub Release.
3. The workflow ends by checking that `releases/latest/download/Plinth.dmg` and `appcast.xml` both answer, so the landing page's download button serves the new version as soon as the run is green. If the landing page links to those two addresses, nothing else needs updating.

Each installed Plinth checks the feed once a day. It downloads the update in the background and installs it when the app quits. People can also choose **Plinth › Check for Updates…**.

Sparkle only accepts an update signed with your private Sparkle key, and macOS only opens an app signed with your Developer ID and notarized by Apple.

## One-time setup

You need your Apple Developer Program membership. Allow about 15 minutes. Nothing here is committed to the repo; the secrets live in GitHub's encrypted secrets.

### 1. Developer ID certificate

1. In Xcode, open **Settings › Accounts**, select your team, click **Manage Certificates…**, then **+ › Developer ID Application**.
2. Open **Keychain Access** and find **Developer ID Application: *Your Name* (TEAMID)** under My Certificates.
3. Right-click it, choose **Export…**, save it as `DeveloperID.p12` and set a password.
4. Note your **Team ID**: the 10 characters in brackets, also listed under Membership at developer.apple.com.

### 2. App Store Connect API key (for notarization)

1. Go to [App Store Connect](https://appstoreconnect.apple.com) › **Users and Access › Integrations › App Store Connect API › Team Keys**.
2. Click **+** and give the key the **Developer** role.
3. Download the `.p8` file (you can only download it once).
4. Note the **Key ID** and the **Issuer ID** shown at the top of the page.

### 3. Sparkle update keys

These keys sign updates. Build the Xcode project once (⌘B) so Sparkle's tools are downloaded, then run:

```bash
"$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1)"
```

This stores a new private key in your login keychain and prints the **public key**. Next, export the private key for GitHub:

```bash
"$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1)" -x sparkle_private.key
```

> **Back up the private key** in your password manager. If it's lost, existing installs can never verify another update, and everyone would have to download Plinth again.

### 4. Add everything to GitHub

From the repo folder, with the files from the steps above, run:

```bash
gh secret set DEVELOPER_ID_CERT_P12 --body "$(base64 -i DeveloperID.p12)"
```

```bash
gh secret set DEVELOPER_ID_CERT_PASSWORD
```

```bash
gh secret set APPLE_TEAM_ID
```

```bash
gh secret set ASC_KEY_ID
```

```bash
gh secret set ASC_ISSUER_ID
```

```bash
gh secret set ASC_KEY_P8 --body "$(base64 -i AuthKey_XXXXXXXXXX.p8)"
```

```bash
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private.key
```

```bash
gh variable set SPARKLE_PUBLIC_KEY
```

The commands without `--body` prompt for the value, so it never lands in your shell history. Afterwards, delete the local copies of `DeveloperID.p12`, the `.p8` file and `sparkle_private.key`, once they're backed up.

## Cutting a release

1. Optionally write release notes in `release-notes/0.2.0.md`. They appear on the GitHub Release and in the update window.
2. Tag and push:

   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```

3. Watch the **Release** workflow in the Actions tab. It takes about 10–15 minutes, most of it waiting for Apple's notary service.

The version comes from the tag. The build number is the commit count, so it always increases, which Sparkle needs.

### Releasing from your Mac instead

Store the notarization key once:

```bash
xcrun notarytool store-credentials plinth-notary --key AuthKey_XXXXXXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

Then build a release. Sparkle signs with the key in your keychain:

```bash
TEAM_ID=<TEAMID> SPARKLE_PUBLIC_KEY=<public key> NOTARY_PROFILE=plinth-notary Scripts/release.sh 0.2.0
```

To publish it, upload the two files:

```bash
gh release create v0.2.0 build/release/Plinth.dmg build/release/appcast.xml --title "Plinth 0.2.0" --generate-notes
```

### Dry run

`UNSIGNED=1 Scripts/release.sh 0.0.0` builds an ad-hoc signed DMG without notarization or a feed. It's useful for checking the packaging; CI runs it on every push.

## Later: iCloud sync in releases

When you add the iCloud capability (see [docs/icloud-sync.md](docs/icloud-sync.md)), Developer ID builds need a **Developer ID provisioning profile** that includes the iCloud container. Create it at developer.apple.com under Profiles. Then add it to the export options in `Scripts/release.sh` (`provisioningProfiles` → `app.plinth.Plinth`) and to the workflow as another secret.
