# App Store screenshot provenance

- Final canvas: 1260 x 2736 px, portrait PNG, opaque background.
- Deterministic renderer: `../Source/render.swift`.
- Editable layout reference: `../Source/index.html`.
- Product UI sources: existing deterministic captures under `../../Screenshots/`.
- Product UI sources are captured with the DEBUG-only Pro test entitlement, so Free badges are excluded from the final asset set.
- The tags-and-folders composition preserves both source screens and varies only their position and rotation.
- Marketing typography: Zen Maru Gothic Black and Bold from the Google Fonts project, licensed under the SIL Open Font License in `../Source/Fonts/OFL.txt`.
- Text and UI are composed deterministically; no generated or altered UI content is used.
- Only `04-action-button.png` includes a black, white-text `PRO` badge, composed deterministically by the renderer.
- Intended locale: English.
