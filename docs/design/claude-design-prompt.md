# Prompt for Claude Design

Create a high-fidelity redesign of a native macOS utility called **Player Identity**.
Audience: technical GoldSrc/Xash3D players. Tone: calm, precise, dense but readable. Native macOS look.

Design two screens:
1. Main window, default 900×760: a status bar, a profile card (player name/model dropdowns, model thumbnail,
   raw identity, source path, gamedir, data root, Apply), a network card (public IP, ranges, interfaces, VPN,
   egress), and a servers list (grouped sections, favourite star, watch bell, ban status with Fix, map/players/
   ping, resolved IP, filters, add server), plus a reasons/suggestions area.
2. Settings, ~600×520, two tabs — General (ban checks, notification categories + quiet hours, language,
   menu bar, launch at login, data root, export/import settings, diagnostics) and Updates (current version,
   auto-check/download, check now, progress, version history with downgrade).

Use the existing visual language: SF Pro, SF Mono for IDs/CIDs, slate #1B2432 surfaces, teal accent #2FB6A8,
status green #34C759 / orange #FF9F0A / red #FF453A, 12 pt card radius, 8 pt spacing grid, 1 px subtle borders.
Deliver light and dark appearance, Turkish and English labels, and include empty, loading, error and disabled
states. Do not use external fonts or icon fonts; use SF Symbols. Every status must have a text label for
accessibility. Values like CIDs are 32 hex characters and must not break the layout.

Return: hi-fi mockups for both screens (both appearances, both languages) and notes on spacing, type scale,
and interaction for refresh, apply-with-diff, filters, update banner and import/export sheets.
