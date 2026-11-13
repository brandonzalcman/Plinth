# Apple Passwords and passkeys in Plinth

Status: **not enabled.** The README says system Passwords autofill and passkeys need an Apple entitlement. This note is how to ask Apple for it. (An earlier version of this process lived in `RELEASING.md`; it is here now.)

## What Apple offers on macOS

- **Passkeys and security keys in a browser:** `com.apple.developer.web-browser.public-key-credential` (macOS 13.3 and later). Only the **Account Holder** of an organization's Apple Developer account can request it, with the form [macOS Browsers Passkeys](https://developer.apple.com/contact/request/macos-browsers-passkeys/). Apple reviews it against fixed criteria: the app declares `http` and `https` in `Info.plist`, shows an address bar, search or bookmarks on launch, and opens URLs directly at their destination. Other roles get an access error on the form. Reports in the Apple developer forums say a request can take weeks, and that an "issued" email can arrive before the capability appears on the App ID, so follow the support case.
- **Default browser:** `com.apple.developer.web-browser` is an **iOS and iPadOS** entitlement (request form: [Default browser entitlement](https://developer.apple.com/contact/request/default-browser-entitlement/)). macOS has no such entitlement: on a Mac any browser that declares `http` and `https` can be chosen under System Settings › Desktop & Dock › Default web browser, and Plinth already can be.
- **Passwords AutoFill from the Passwords app:** Apple does not document a separate entitlement for third-party `WKWebView` browsers on macOS. Test it first on a real sign-in form in a signed build; macOS 26 may already autofill.

## Why the entitlement is not in `App/Plinth.entitlements`

It is a restricted entitlement. Apple adds it to the team as a managed capability, and it has to be backed by a provisioning profile. If the key is added before approval, a signed build can refuse to launch, and the no-team local builds (`Scripts/bundle.sh`) would break. Add it only after Apple approves.

## Steps

1. The Account Holder signs in at developer.apple.com and submits the [macOS Browsers Passkeys](https://developer.apple.com/contact/request/macos-browsers-passkeys/) form for `app.plinth.Plinth`: macOS web browser, Developer ID distribution, open source (GPL v3), site getplinth.dev.
2. When Apple approves, enable **Web Browser Public Key Credential** on the App ID `app.plinth.Plinth` (Certificates, Identifiers & Profiles › Identifiers) and regenerate the Developer ID provisioning profile (the one `RELEASING.md` describes for iCloud; one profile carries both).
3. Add `com.apple.developer.web-browser.public-key-credential` (boolean `true`) to `App/Plinth.release.entitlements`, not to `App/Plinth.entitlements`, so no-team builds keep working. Update the `DEVELOPER_ID_PROFILE` secret with the new profile.
4. Run `UNSIGNED=1 Scripts/release.sh 0.0.0` to check the packaging still builds, then do a normal signed release.

## What to test after

- A sign-in form on a real site: does the Passwords suggestion appear in the field?
- A passkey sign-in on a site that supports passkeys: does the sheet appear and complete?
- The no-team local build still launches.
