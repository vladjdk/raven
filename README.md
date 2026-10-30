# Raven

A fast, keyboard-first, agent-forward email client for macOS. Native SwiftUI, local-first, open source.

> Early days (v0.1). See [docs/SPEC.md](docs/SPEC.md) for the plan.

## Build

```bash
brew install xcodegen
scripts/bootstrap-nanocode.sh   # fetches the pinned agent runtime into Vendor/ and checks its SHA-256
xcodegen generate
open Raven.xcodeproj
```

Plain-English requests in ⌘K (“archive the newsletters except The Weekly Byte”) need an Anthropic API key, added in Settings. It's stored in your Keychain.

Run with `--demo` (or click **Explore with sample mail**) to try it without a Google account.
To sign in with Gmail, create a Google Cloud OAuth client of type *Desktop app* with the Gmail API enabled,
and put its id and secret in `Config/Secrets.xcconfig` (see the example file).

- **Instant:** every action is local first, with sync afterward.
- **Keyboard everything:** `j/k`, `e`, `h`, `⌘K`.
- **Agent built in:** an embedded [nanocode](https://github.com/gakonst/nanocode-swift) agent that triages and drafts using the same tools you do. It never sends without you.
- **No server:** your mail goes from your provider to your Mac. Keys live in the Keychain.

## Contributing: secrets

This repo is public. Before your first commit:

```bash
brew install gitleaks
git config core.hooksPath .githooks
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # gitignored; put your own OAuth client here
```

The pre-commit hook and CI both run gitleaks and block commits that contain secrets.

## License

MIT
