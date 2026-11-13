# Releasing Plinth

Plinth ships as a signed, notarized disk image on GitHub Releases, named with its version (`Plinth-0.1.2.dmg`). Installed copies update themselves with [Sparkle](https://sparkle-project.org), so people download the app once and get every later version automatically.

- **Download** (the address the landing page's button and the update feed both use):
  `https://github.com/brandonzalcman/Plinth/releases/download/v<version>/Plinth-<version>.dmg`
- **Update feed** that the app checks (built into `Scripts/Info.plist`):
  `https://github.com/brandonzalcman/Plinth/releases/latest/download/appcast.xml`

## How updates reach people

1. You start a release yourself: run the **Release** workflow by hand, or push a tag such as `v0.2.0` (see [Cutting a release](#cutting-a-release)). Merging pull requests into `main` never publishes anything, so many small changes can land between releases.
2. The **Release** workflow builds the app, signs it with your Developer ID, notarizes it with Apple and builds `Plinth-<version>.dmg`. It also writes `appcast.xml`, signed with your Sparkle key, whose download points at that DMG. It publishes the two files as a GitHub Release.
3. The workflow ends by checking that the DMG and `appcast.xml` both answer. There is no fixed-name copy of the DMG: the landing page looks up the newest release when it loads and points its download button at that release's DMG, so it needs no change per release. (Its no-JavaScript fallback link is stamped when the site is deployed, so redeploy the site after a release to refresh that too.)

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

Nothing is released by merging. When `main` holds what you want to ship:

1. Merge a small pull request that raises `MARKETING_VERSION` in `Plinth.xcodeproj` and adds `release-notes/<version>.md`. The notes appear on the GitHub Release and in the update window.
2. Start the release, either way:

   ```bash
   gh workflow run release.yml
   ```

   or open the Actions tab, choose **Release** and press **Run workflow**. With the version box left empty it releases the version in the Xcode project; type a version to override it. Pushing a tag does the same thing:

   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```

3. Watch the **Release** workflow in the Actions tab. It takes about 5 minutes, most of it the archive and Apple's notary service. If that version is already published, the run stops without doing anything.

A tag sets the version from its name. The build number is the commit count, so it always increases, which Sparkle needs.

### Releasing from your Mac instead

Store the notarization key once:

```bash
xcrun notarytool store-credentials plinth-notary --key AuthKey_XXXXXXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

Then build a release. Sparkle signs with the key in your keychain:

```bash
TEAM_ID=<TEAMID> SPARKLE_PUBLIC_KEY=<public key> NOTARY_PROFILE=plinth-notary Scripts/release.sh 0.2.0
```

To publish it, upload the two files (the DMG and the feed):

```bash
gh release create v0.2.0 build/release/Plinth-0.2.0.dmg build/release/appcast.xml --title "Plinth 0.2.0" --generate-notes
```

### Dry run

`UNSIGNED=1 Scripts/release.sh 0.0.0` builds an ad-hoc signed `Plinth-0.0.0.dmg` without notarization or a feed. It's useful for checking the packaging; CI runs it on pull requests that change the scripts, the Xcode project or the workflows.

## iCloud sync in releases (optional)

Signed releases carry the iCloud (CloudKit) entitlement only when the workflow has a **Developer ID provisioning profile** for `app.plinth.Plinth` that includes the container `iCloud.dev.getplinth.Plinth`. Without the profile secret a release is built exactly as before, with no iCloud, and the app's iCloud switch says it needs a developer team. So the release is safe to run at any point of this setup.

How it fits together: `Scripts/release.sh` takes the profile in `PROVISIONING_PROFILE`. With it, the archive is signed with `App/Plinth.release.entitlements` (the iCloud keys; `App/Plinth.entitlements` stays empty so no-team builds work), the export options map `app.plinth.Plinth` to the profile and set the CloudKit environment to Production, and the script fails the release if the exported app lacks the container. The workflow decodes the profile from the `DEVELOPER_ID_PROFILE` secret.

One-time setup (the account steps are done by you, on developer.apple.com and in CloudKit Console):

1. **Register the container.** developer.apple.com › Certificates, Identifiers & Profiles › Identifiers › **+** › **iCloud Containers**. Description `Plinth`, identifier `iCloud.dev.getplinth.Plinth`.
2. **Enable iCloud on the App ID.** Identifiers › `app.plinth.Plinth` (create it as a macOS App ID if it does not exist; if Apple says the bundle ID is taken, stop and tell the maintainers, because changing it would break updates for installed copies) › check **iCloud** › **Configure**, choose **Include CloudKit support**, tick `iCloud.dev.getplinth.Plinth` › Save.
3. **Create the profile.** Profiles › **+** › Distribution › **Developer ID** › App ID `app.plinth.Plinth` › your Developer ID Application certificate › name it `Plinth Developer ID` › Generate and download it (`Plinth_Developer_ID.provisionprofile`).
4. **Add it to GitHub** from the folder with the file:

   ```bash
   gh secret set DEVELOPER_ID_PROFILE --body "$(base64 -i Plinth_Developer_ID.provisionprofile)"
   ```

   Delete the local copy afterwards. The profile is invalidated if you change the App ID's capabilities; generate and upload it again then.
5. **Deploy the schema to Production** (see "Deploying the CloudKit schema" in [docs/icloud-sync.md](docs/icloud-sync.md)). A release build talks to Production, which has no record types until you deploy them, so sync fails with "unknown record type" before that.
6. Run a release. The log's "Exporting with Developer ID (with iCloud)" line confirms the profile was used.

To release from your Mac, add `PROVISIONING_PROFILE=/path/to/Plinth_Developer_ID.provisionprofile` to the command above.
