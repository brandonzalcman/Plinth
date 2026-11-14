# Contributing to Plinth

Thanks for helping. Plinth is a small, opinionated browser, so changes that keep it calm and simple are the easiest to accept.

## Before you start

- **Bugs:** open an issue with steps to reproduce, your macOS version and what you expected.
- **Features:** open an issue to discuss before you write code. Plinth deliberately has no toolbar, no tab strip and no extensions, so proposals that add chrome are unlikely to land.
- **Security problems:** please don't open a public issue; follow [SECURITY.md](SECURITY.md).

## Set up

You need macOS 26 and Xcode 26 (Swift 6.2).

```bash
git clone https://github.com/brandonzalcman/Plinth.git
```

```bash
cd Plinth && swift build && swift test
```

To work in Xcode, open `Plinth.xcodeproj` and run the **Plinth** scheme. It signs to run locally, so no account is needed. The code lives in the Swift package; the project only adds the app bundle (`App/`, `Scripts/Info.plist`, entitlements). Don't commit your own Team ID in the project file. If `swift` can't find the SDK, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Run the app on a throwaway profile, so your own browsing data is never touched:

```bash
Scripts/bundle.sh && open -n build/Plinth.app --env PLINTH_STORAGE=/tmp/plinth-dev
```

A fresh throwaway profile opens getplinth.dev as its first page, so that launch loads the site over the network. Any other `PLINTH_` variable (for example `PLINTH_OPEN`) skips it.

`PLINTH_AI=fake` lets you work on the AI interface on a Mac without Apple Intelligence.

## How the code is organised

Each module has one job, and modules depend only on `PlinthModel` (value types and protocols). The README's [Architecture](README.md#architecture) section has the map. In short:

- **Pure logic** has unit tests and no UI or WebKit: `PlinthRules`, `PlinthFade`, `PlinthLayout`, `PlinthStore`, `PlinthAI`, `PlinthSync`.
- **UI and WebKit:** `PlinthBarUI`, `PlinthPanels`, `PlinthWeb`.
- **The app shell** (`Sources/PlinthApp`) wires the store's events to web views and panels.

If a change needs a new type shared between modules, add it to `PlinthModel` first and keep it a plain value type or protocol.

## Conventions

- **Language mode.** Swift 6 strict concurrency for the logic modules; the UI targets use Swift 5 language mode, as set in `Package.swift`.
- **Warnings.** `swift build` should stay free of warnings.
- **Tests.** Write them for new logic, using Swift Testing (`import Testing`, `@Test`, `#expect`). Tests must not touch the network or your real profile.
- **Brand.** UI follows [docs/brand-guide.md](docs/brand-guide.md): system font, the Ink, Stone, Sand and Sky palette, light and dark.
- **Comments.** Keep them short and about *why*.
- **AI features** must respect the master switch and degrade quietly when the model is unavailable. Keyword search must never depend on AI.

## Sending a pull request

1. Fork the repo and create a branch from `main`.
2. Make your change, with tests where it makes sense.
3. Run `swift build` and `swift test`. Both must pass with no new warnings.
4. For anything visible, try it in the bundled app and attach a screenshot to the PR.
5. Open the pull request and describe what changed and why.

By contributing, you agree that your contributions are licensed under the [GPL v3](LICENSE), the project's license.

## Code of conduct

Be kind and constructive. Harassment or personal attacks aren't welcome in issues, pull requests or discussions; maintainers may remove such content and block people who post it.
