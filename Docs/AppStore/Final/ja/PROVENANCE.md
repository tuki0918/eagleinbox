# App Store screenshot provenance — Japanese

- Final canvas: 1260 x 2736 px, portrait PNG, opaque background.
- Deterministic renderer: `../../Source/render.swift` with `--locale ja`.
- Product UI sources: Japanese (`ja-JP`) iPhone Simulator captures under `../../../Screenshots/ja/`.
- Marketing headlines and subtitles are localized into Japanese.
- The Pro purchase screen was captured by the UI test screenshot mode and uniformly resized to the final source canvas; its UI content was not retouched.
- Folder and tag names remain English because they represent user-owned Eagle library data; surrounding app UI is localized in Japanese.
- The tags-and-folders composition preserves both source screens and varies only their position and rotation.
- The Action Button source is an actual Japanese system screen showing Eagle Inbox's localized App Intent.
- Marketing typography: Zen Maru Gothic Bold from the Google Fonts project, licensed under the SIL Open Font License in `../../Source/Fonts/OFL.txt`. Japanese type is set slightly smaller than the English version for balanced visual weight.
- Text and UI are composed deterministically; no generated or altered UI content is used.
- Only `05-action-button.png` includes a `PRO` badge, composed by the renderer.
- Intended locale: Japanese (`ja-JP`).
