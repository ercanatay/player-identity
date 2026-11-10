# Player Identity — UI/UX redesign brief

## Product
macOS utility (SwiftUI) for Xash3D/GoldSrc players. It shows identity data, per-server CIDs and ban status,
and helps act on bans. Technical audience; values are dense, must stay readable.

## Screens in scope
1. **Main window** (default 900×760, min 720×520) — status, profile, network, servers, reasons.
2. **Settings** (600×~520, tabbed: General, Updates) — integrations, updates, data tools, language.

## Design system (derive from the app, do not invent a new brand)
- Typography: SF Pro / system. Title 22 semibold, section 13 semibold uppercase-ish, body 13, monospace for
  IDs/CIDs/IPs (SF Mono 13).
- Colours: slate `#1B2432`, teal accent `#2FB6A8`, status green `#34C759`, orange `#FF9F0A`, red `#FF453A`.
  Support light and dark appearance; use system semantic colours where possible.
- Surfaces: cards with 12 pt radius, 1 px border at 8% opacity, 16 pt padding; 8 pt spacing grid.
- Controls: native macOS controls, no custom window chrome; SF Symbols only; no external fonts or icon fonts.
- Accessibility: contrast AA, every status has text (never colour alone), full VoiceOver labels, keyboard order.

## Main window requirements
- **Top bar:** status icon + label, last check time, Refresh (⌘R), Save (⌘S). Optional update banner above.
- **Profile card:** player name + model as editable dropdowns, model thumbnail, raw identity (monospace),
  identity source path, gamedir, data root, Apply with diff preview.
- **Network card:** public IP (copyable), /24 + /16 ranges, interfaces with VPN badge, egress line.
- **Servers:** grouped sections, favourite star, watch bell, ban column (icon + text + Fix), map · players ·
  ping, resolved host → IP; filters (banned / favourite / watched); add server.
- **Reasons/suggestions:** each reason with icon, message and a one-line action hint; popover with all actions.
- Long technical values must truncate gracefully with tooltips; rows must not jump when values change.

## Settings requirements
- **General:** ban checks, notifications (master + ban/online/map + quiet hours), language (System/Türkçe/English),
  menu bar, launch at login, data root, data tools (export/import settings, diagnostics), reset options.
- **Updates:** current version, last check, auto-check/download, check now, status/progress, version history with
  downgrade and data backup note.
- Group related controls into cards; destructive actions separated and confirmed.

## Deliverables
- High-fidelity mockups: main window + Settings (General, Updates), light + dark, TR + EN.
- Component notes: spacing, type scale, empty/error states, progress, disabled states.
- Interaction notes for: refresh, apply-diff, filters, update banner, import/export sheets.

## Implementation constraint
SwiftUI on macOS 14+, native controls, no third-party packages; strings localized (TR/EN) and variable-length safe.
