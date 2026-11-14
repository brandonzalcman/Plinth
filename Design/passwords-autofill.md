# Apple Passwords and passkeys in Plinth

Status: **Apple approved the passkeys entitlement for `app.plinth.Plinth` (Mac only).** The release script signs it in when the provisioning profile carries it; until the profile is regenerated (steps in `RELEASING.md`, "Passkeys in releases") releases ship without passkeys. Passwords autofill into forms is a separate question and is still untested.

## What Apple offers on macOS

- **Passkeys and security keys in a browser:** `com.apple.developer.web-browser.public-key-credential` (macOS 13.3 and later). Only the **Account Holder** of an organization's Apple Developer account can request it, with the form [macOS Browsers Passkeys](https://developer.apple.com/contact/request/macos-browsers-passkeys/). Apple reviews it against fixed criteria: the app declares `http` and `https` in `Info.plist`, shows an address bar, search or bookmarks on launch, and opens URLs directly at their destination. Other roles get an access error on the form. Reports in the Apple developer forums say a request can take weeks, and that an "issued" email can arrive before the capability appears on the App ID, so follow the support case.
- **Default browser:** `com.apple.developer.web-browser` is an **iOS and iPadOS** entitlement (request form: [Default browser entitlement](https://developer.apple.com/contact/request/default-browser-entitlement/)). macOS has no such entitlement: on a Mac any browser that declares `http` and `https` can be chosen under System Settings › Desktop & Dock › Default web browser, and Plinth already can be.
- **Passwords AutoFill from the Passwords app:** Apple does not document a separate entitlement for third-party `WKWebView` browsers on macOS. Test it first on a real sign-in form in a signed build; macOS 26 may already autofill.

## Why the entitlement is not in `App/Plinth.entitlements`

It is a restricted entitlement. Apple adds it to the team as a managed capability, and it has to be backed by a provisioning profile. If the key is added before approval, a signed build can refuse to launch, and the no-team local builds (`Scripts/bundle.sh`) would break. `Scripts/release.sh` therefore adds it to a copy of `App/Plinth.release.entitlements` only when the profile it is given carries it.

## Findings on how the app uses it

- `WKWebView` performs WebAuthn itself. WebKit builds the `ASAuthorizationController` request inside its UI process (`WebAuthenticatorCoordinatorProxy`) and the system decides whether the host app may ask for any relying party; the host app needs only the entitlement. WebKit's own comment on bug 250912 says passkeys in a `WKWebView` are allowed only "in an entitled web browser or has matching associated domain". So Plinth has no native passkey code and does not call `ASAuthorizationWebBrowserPublicKeyCredentialManager` (that class is for apps that drive requests themselves) or request platform-credential authorization.
- Apple's entitlement page does not say this; it is read from WebKit's source and bug tracker, plus developer forum reports that demo pages began to work once the entitlement arrived. Reasonably sure, not confirmed on a signed Plinth build yet.
- Private windows use a non-persistent data store but offer passkeys like any window; the credentials live in iCloud Keychain, not in Plinth.

## Steps (done by the account holder)

1. Apple approved the [macOS Browsers Passkeys](https://developer.apple.com/contact/request/macos-browsers-passkeys/) request for `app.plinth.Plinth`.
2. Enable the capability on the App ID, regenerate the Developer ID profile and update `DEVELOPER_ID_PROFILE`: exact steps in `RELEASING.md`, "Passkeys in releases".
3. Release; the log says whether the profile carried the entitlement.

## What to test after

- A sign-in form on a real site: does the Passwords suggestion appear in the field?
- A passkey sign-in on a site that supports passkeys: does the sheet appear and complete?
- The no-team local build still launches.
