# Apple Passwords and passkeys in Plinth

Status: **not enabled in 0.1.1.** The 0.1.0 build report and the README say system Passwords autofill needs an Apple entitlement. This note is what to do to ask Apple for it.

## Why the entitlements are not in `App/Plinth.entitlements` yet

These are restricted entitlements. Apple has to grant them to your team and they have to be backed by a provisioning profile. If the keys are added before approval, a signed build can refuse to launch, and the ad-hoc local builds (`Scripts/bundle.sh`) would break. Add them only after Apple approves.

## Steps

1. Sign in at developer.apple.com with the team that signs Plinth (the Developer ID team from `RELEASING.md`).
2. Request the **Web Browser Public Key Credential** entitlement for macOS (`com.apple.developer.web-browser.public-key-credential`) through Apple's entitlement request form. This is what lets passkeys and WebAuthn work inside a `WKWebView` browser. Describe Plinth as a macOS web browser built on WKWebView.
3. Ask in the same request whether password AutoFill from the Passwords app for third-party WKWebView browsers needs `com.apple.developer.web-browser` or anything else on macOS. Apple's public documentation does not say. One developer forum reply says macOS 26 may already autofill in web views, which is worth testing first on a real login form in a build that you sign.
4. When approved, in Xcode go to Signing & Capabilities, add the capability or keys Apple lists, and let Xcode write them into `App/Plinth.entitlements`. Create or refresh the Developer ID provisioning profile if Apple's email says to.
5. Build with `UNSIGNED=1 Scripts/release.sh <version>` first to check it launches, then do a normal signed release.

## What to test after

- A sign-in form on a real site: does the Passwords suggestion appear in the field?
- A passkey sign-in (for example on a site that supports passkeys): does the sheet appear and complete?
- The ad-hoc local build still launches (the entitlements file must not break `Scripts/bundle.sh`).
