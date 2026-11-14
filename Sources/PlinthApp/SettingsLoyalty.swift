import SwiftUI
import PlinthLoyalty

struct LoyaltySettingsView: View {
    let app: AppController
    @Environment(\.settingsTheme) private var t
    private var sharer: ShareCardSharer { app.cardSharer }

    private func cardContent(_ engine: LoyaltyEngine, _ totals: LoyaltyTotals) -> ShareCardContent {
        let chosen = LoyaltyColourway.named(app.settings.value.appIcon).flatMap { engine.isUnlocked($0) ? $0 : nil } ?? .sunrise
        return ShareCardContent(level: totals.level, points: totals.points, streak: totals.streak, colourway: chosen)
    }

    var body: some View {
        // Reading the revision makes this view refresh when points change.
        let _ = app.loyaltyModel.revision
        let engine = app.loyalty!
        let totals = engine.totals
        SettingsPage(title: "Points & Levels", subtitle: "Plinth gives points for using it. They stay on your devices, and with iCloud sync on they add up across your Mac and iPhone.") {
            if engine.isEnabled {
                SettingsCard(heading: "Your level") {
                    HStack(spacing: 16) {
                        LoyaltyBadge(level: totals.level, colourway: cardContent(engine, totals).colourway, size: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(totals.level.name) · \(totals.points) points").font(.system(size: 15, weight: .semibold)).foregroundStyle(t.p.primary)
                            if let progress = totals.progress, let next = totals.level.next {
                                ProgressView(value: Double(progress.earned), total: Double(progress.needed)).tint(t.accent).frame(maxWidth: 260)
                                    .accessibilityLabel("Progress to \(next.name)")
                                Text("\(progress.needed - progress.earned) points to \(next.name)").font(.system(size: 11.5)).foregroundStyle(t.p.secondary)
                            } else {
                                Text("You have reached the top level.").font(.system(size: 11.5)).foregroundStyle(t.p.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    SettingsDivider()
                    SettingsNote(text: "\(totals.streak)-day streak · \(totals.daysOfUse) \(totals.daysOfUse == 1 ? "day" : "days") of use · \(totals.shares) \(totals.shares == 1 ? "share" : "shares")")
                }

                SettingsCard(heading: "Share") {
                    ShareCardView(content: cardContent(engine, totals))
                        .scaleEffect(0.3, anchor: .topLeading)
                        .frame(width: ShareCardView.size.width * 0.3, height: ShareCardView.size.height * 0.3, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(14)
                        .accessibilityLabel("Share card preview: level \(totals.level.number), \(totals.level.name), \(totals.points) points")
                    SettingsDivider()
                    SettingsRow(title: "Share your level",
                                caption: "Makes an image with your level badge and points, and opens the share sheet. Sharing earns 15 points, up to 3 a day. The card shows no pages or sites.") {
                        ShareAnchorButton(title: "Share…") { view in
                            sharer.present(cardContent(engine, totals), from: view)
                        }.fixedSize()
                    }
                }

                SettingsCard(heading: "Levels and what they unlock") {
                    ForEach(Array(LoyaltyLevel.all.enumerated()), id: \.element.id) { index, level in
                        if index > 0 { SettingsDivider() }
                        let reached = totals.points >= level.threshold
                        let unlock = LoyaltyColourway.all.first { $0.unlockLevel == level.number }
                        SettingsRow(title: "\(level.number). \(level.name)",
                                    caption: unlock.map { "\($0.name) app icon and accent" } ?? "Sunrise app icon and accent") {
                            if reached {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(t.accentText).accessibilityLabel("Reached")
                            } else {
                                Text("\(level.threshold) points").font(.system(size: 12).monospacedDigit()).foregroundStyle(t.p.secondary)
                            }
                        }
                    }
                }

                SettingsCard(heading: "How to earn") {
                    SettingsNote(text: "Using Plinth each day: 10 points, plus a little more for each day in a row. Sharing the Plinth card: 15 points, up to 3 a day. Trying pins, bookmarks, split view, Ask and iCloud sync for the first time: 25 each. Using Plinth on both Mac and iPhone: 50.")
                }
            }

            SettingsCard(heading: "Points") {
                SettingsToggleRow(title: "Earn and show points",
                                  caption: engine.isEnabled ? "Turn this off to hide points and stop earning. What you earned is kept, and so are the icons and colours you unlocked."
                                                              : "Points are off: nothing is earned or shown.",
                                  isOn: Binding(get: { engine.isEnabled }, set: { engine.isEnabled = $0; app.loyaltyModel.bump() }))
            }
        }
    }
}
