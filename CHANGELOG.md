# Changelog

All notable changes to Eagle Inbox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-09-01

### Added

- Added `Get Tags from Eagle` and `Get Folders from Eagle` actions for Apple Shortcuts.
- Added a file import button to the empty upload queue when running the iOS app on an Apple silicon Mac.
- Added a Cloudflare Tunnel template for publishing a restricted Eagle-compatible HTTPS endpoint.

### Changed

- Improved connection error reporting and default port handling in the connection editor.
- Updated Pro upgrade views to use the current purchase state consistently.
- Updated English and Japanese accessibility labels and localization metadata.

## [1.0.0] - 2026-08-24

### Added

- Initial release of Eagle Inbox for iPhone, iPad compatibility mode, and Apple silicon Macs.
- Added direct uploads of photos, videos, audio, PDFs, files, and web URLs to Eagle.
- Added share extension support for sending content from Photos, Files, Safari, and other apps.
- Added batch metadata for folders, annotations, and tags, including recent folder and tag choices.
- Added HTTP and HTTPS connections, optional API tokens, connection testing, and destination library verification.
- Added upload progress, cancellation, retry, and privacy-safe release diagnostics.
- Added English and Japanese localization.
- Added Eagle Inbox Pro as a one-time purchase, unlocking Apple Shortcuts, Action Button workflows, and unlimited saved connections.
- Added Shortcuts actions for sending files and URLs, optional tags and annotations, and splitting text into tags.

### Security

- Stored API tokens in Keychain.
- Added destination library mismatch warnings and confirmation before uploading to a different open library.

[Unreleased]: https://github.com/tuki0918/eagleinbox/compare/v1.1...HEAD
[1.1.0]: https://github.com/tuki0918/eagleinbox/compare/v1.0...v1.1
[1.0.0]: https://github.com/tuki0918/eagleinbox/releases/tag/v1.0
