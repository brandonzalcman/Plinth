# Plinth: brand and design guide

Nov 13, 2026 · @Brandon

Plinth's brand is an arched window showing a sunrise, standing on a two-step base, with Sunrise (blue to peach on cream) as the primary colourway. Visual reference: [Plinth brand board](https://claude.ai/artifact/EkAN5EQx6gqTELFvWjgALE).

## Logo

The icon is an arched window standing on a two-step base. The arch is a doorway onto the web; the base is the plinth, and echoes the floating bar at the bottom of the browser.

- **Icon parts:** a rounded-square tile, the arch filled with a vertical sky gradient, a pale sun rising from the bottom of the arch, a dark frame around the arch, and two dark steps beneath it.
- **Wordmark:** "Plinth" in Space Grotesk Semibold (600), letter-spacing about -0.045em, capital P only.
- **Primary lockup:** icon on the left, wordmark on the right, vertically centred. The gap between them is roughly a quarter of the icon's width.
- **Backgrounds:** the lockup works on white, on Stone and on Ink. On Ink the wordmark switches to Stone; the icon tile stays as it is.
- **Do not:** recolour individual parts, rotate the icon, add effects, or place the wordmark inside the tile.

## Icon colourways

Sunrise is the primary. The others are alternates for dark mode, one-colour printing and optional user-selectable app icons.

| Colourway | Use | Tile | Sky gradient (top, 60%, bottom) | Sun | Frame and base |
| --- | --- | --- | --- | --- | --- |
| Sunrise | Primary | #F6F1E7 | #2F5BEA, #93AAFF, #FFC9A3 | #FFF1DA | #1C1C1A |
| Dusk | Dark mode | #1B1A2E | #3A2A7A, #B0509A, #FF9E7A | #FFE0B8 | #F4EEE6 |
| Meadow | Alternate | #EEF3E8 | #0F6B5B, #7CC8A6, #F4E7A1 | #FFFBE0 | #14231F |
| Ember | Alternate | #FBEDE3 | #B8361E, #F08A4B, #FFD9A0 | #FFF3D6 | #2A1712 |
| Midnight | Alternate, dark | #0E1220 | #0B1E5B, #2F5BEA, #8FD3FF | #EAF6FF | #E9ECF5 |
| Mono | One-colour use | #FFFFFF | Solid #1C1C1A | #FFFFFF | #1C1C1A |

Light tiles carry a 1 px border a shade darker than the tile (Sunrise: #D9D0BC) so they hold their edge on pale backgrounds.

## Colour palette

The palette is taken from the Sunrise icon. Sky is the only strong accent; Dawn is used sparingly.

| Name | Hex | Role |
| --- | --- | --- |
| Ink | #1C1C1A | Text, icon frame and base, pinned-site tiles |
| Stone | #F6F1E7 | Icon tile, site capsules, soft surfaces |
| Sand | #E3DCCB | Borders and dividers |
| Sky | #2F5BEA | Accent: current page, primary buttons, links |
| Haze | #93AAFF | Hover and highlight states |
| Dawn | #FFC9A3 | Warm accent: fading sites, gentle notices |

Supporting neutrals: page background #FBF8F2, white #FFFFFF for the bar and content surfaces, secondary text #4A4A45.

White text on Sky and Ink text on Stone both meet the 4.5:1 contrast minimum. Do not set text in Haze or Dawn on a light background.

## Typography

| Typeface | Where | Weights |
| --- | --- | --- |
| Space Grotesk | Wordmark, marketing headings | 500, 600, 700 |
| macOS system font (SF Pro) | Everything inside the app | System text styles |
| Inter | Website and documents, standing in for the system font | 400, 500, 600 |

Inside the app, use the system font and standard macOS text styles so Plinth feels native. Space Grotesk appears in the app only where the wordmark itself is shown, such as the About window and onboarding.

## Icon sizes

- **64 px and above:** the full icon, with sun, frame and both steps.
- **32 px and below:** the simplified icon. Drop the sun and the second step, widen the arch slightly, thicken the frame, and use a two-stop gradient (Sky to Dawn).
- The macOS app icon set needs 16, 32, 128, 256 and 512 pt, each at 1x and 2x. Use the simplified drawing for 16 and 32 pt and the full drawing for the rest.
- Corner radius of the tile is about 23% of its width (64 on a 280 grid). When exporting the real app icon, use Apple's icon template shape in place of this approximation.

## Bottom bar styling

How the palette applies to the floating bottom bar described in the feature plan.

| Element | Style |
| --- | --- |
| Bar | White, 1 px Sand border, 20 pt corner radius, 64 pt tall, soft shadow (Ink at about 14% opacity, 32 pt blur, 10 pt down) |
| Pinned site tile | 44 pt square, 12 pt radius, Ink fill, Stone letter or the site's own icon |
| Divider | 1 pt wide, 28 pt tall, Sand |
| Site capsule | Stone fill, 14 pt radius, 48 pt tall, led by a 16 pt site icon |
| Page button | 44 pt tall, 12 pt radius, 13 pt medium text in #4A4A45, transparent fill |
| Current page | Sky fill, white semibold text |
| Hover | Haze at low opacity behind the button |
| Fading site | Dashed 1 pt border in #C9B9A0, regular-weight text, Dawn icon tint |
| Search button | #FBF8F2 fill, Sand border, "Search" and the ⌘L hint |

Dark mode is not designed yet. The starting point is the Dusk colourway: tile colour #1B1A2E for surfaces and #F4EEE6 for text.

## Icon source

Both drawings sit on a 280 by 280 grid. Swap the colours from the colourways table to produce the other versions.

Full icon, Sunrise:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 280 280">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2F5BEA"/>
      <stop offset="0.6" stop-color="#93AAFF"/>
      <stop offset="1" stop-color="#FFC9A3"/>
    </linearGradient>
    <clipPath id="arch">
      <path d="M92 192 V108 a48 48 0 0 1 96 0 V192 Z"/>
    </clipPath>
  </defs>
  <rect x="0.5" y="0.5" width="279" height="279" rx="64" fill="#F6F1E7" stroke="#D9D0BC"/>
  <path d="M92 192 V108 a48 48 0 0 1 96 0 V192 Z" fill="url(#sky)"/>
  <circle cx="140" cy="186" r="26" fill="#FFF1DA" clip-path="url(#arch)"/>
  <path d="M92 192 V108 a48 48 0 0 1 96 0 V192" fill="none" stroke="#1C1C1A" stroke-width="10" stroke-linejoin="round"/>
  <rect x="72" y="190" width="136" height="20" rx="4" fill="#1C1C1A"/>
  <rect x="50" y="214" width="180" height="20" rx="4" fill="#1C1C1A"/>
</svg>
```

Simplified icon for 32 px and below:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 280 280">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2F5BEA"/>
      <stop offset="1" stop-color="#FFC9A3"/>
    </linearGradient>
  </defs>
  <rect x="4" y="4" width="272" height="272" rx="62" fill="#F6F1E7" stroke="#D9D0BC" stroke-width="8"/>
  <path d="M84 196 V112 a56 56 0 0 1 112 0 V196 Z" fill="url(#sky)" stroke="#1C1C1A" stroke-width="18" stroke-linejoin="round"/>
  <rect x="48" y="194" width="184" height="38" rx="6" fill="#1C1C1A"/>
</svg>
```

## Open items

- [ ] Tagline: "A calm browser for Mac." is a placeholder.
- [ ] Wordmark typeface: Space Grotesk is a first pick, not yet confirmed.
- [ ] Dark mode palette and bar styling.
- [ ] Final app icon export using Apple's icon template, checked at 16 px on a real display.
- [ ] Trademark and App Store check on the name Plinth before a commercial release.
