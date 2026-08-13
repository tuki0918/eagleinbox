# App Store screenshot provenance

- Final canvas: 1260 x 2736 px, portrait PNG, opaque background.
- Deterministic renderer: `../Source/render.swift`.
- Editable layout reference: `../Source/index.html`.
- Product UI sources: existing deterministic captures under `../../Screenshots/`.
- Product UI sources are captured with the DEBUG-only Pro test entitlement, so Free badges are excluded from the final asset set.
- The tags-and-folders composition preserves both source screens and varies only their position and rotation.
- Marketing typography: Zen Maru Gothic Black and Bold from the Google Fonts project, licensed under the SIL Open Font License in `../Source/Fonts/OFL.txt`.
- Text and UI are composed deterministically. `05-pro-upgrade.png` uses the approved DEBUG-only screenshot presentation mode, which displays `Unlock Pro` without a localized price for a public, locale-neutral product-page image.
- Only `04-action-button.png` includes a black, white-text `PRO` badge, composed deterministically by the renderer.
- `05-pro-upgrade.png` uses a direct 1260 x 2736 px Simulator capture from the DEBUG-only screenshot presentation mode; no UI pixels or copy were synthesized or retouched.
- Intended locale: English.
