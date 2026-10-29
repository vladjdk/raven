# Raven — product & technical spec

Status: draft v0.1 (2026-10-28)

Raven is an open-source, native macOS email client that's fast and keyboard-first, with an agent built in. It's a clean-room product. We build from public behavior and our own ideas, never from another client's code, assets or copy.

## 1. Principles

1. **Instant.** Every action responds in under 100 ms, because it happens locally first and syncs afterward. If the network is slow, the UI still isn't.
2. **The keyboard does everything.** Every action has a key, and `⌘K` reaches anything. The mouse works but is never required.
3. **Agent-forward.** The agent is a first-class way to use the app, not a sidebar chatbot. It reads, triages and drafts using the same tools you use.
4. **Your mail, your machine, your keys.** No Raven server. Mail syncs straight from the provider to a local database. API keys and OAuth tokens live in the Keychain.
5. **The agent proposes; the human sends.** The agent can draft, label, archive and snooze, and every action can be undone. Sending always needs a human keypress.

## 2. Platform & stack

| Layer | Choice | Why |
|---|---|---|
| App | Swift 6 + SwiftUI, AppKit where SwiftUI falls short (list virtualization, text input) | Native feel, low memory, real macOS integration (Keychain, notifications, Spotlight, Shortcuts) |
| Targets | macOS 15+ first; iOS later, sharing the core package | |
| Store | SQLite (GRDB) with FTS5 for search | Local-first; search is instant and works offline |
| Mail rendering | WKWebView in a locked-down configuration: JavaScript off, remote content proxied/blocked by default, CSP | Email HTML is hostile input |
| Providers | Gmail API (OAuth 2 + PKCE) first; JMAP and IMAP next | Gmail is the first account we test with; JMAP/IMAP avoid Google lock-in |
| Agent | [nanocode](https://nanocode.xyz) via [nanocode-swift](https://github.com/gakonst/nanocode-swift) (MIT/Apache-2.0), a SwiftPM dependency pinned to an exact revision | Claude/Codex agent runtime embedded in the app (Rust core, prebuilt XCFramework). Durable sessions in local SQLite, host tools, sandboxed Code Mode. No sidecar, no Python |
| Code layout | `RavenCore` (sync, store, providers: Swift package), `RavenAgent` (agent bridge), `RavenApp` (UI) | Core is testable without UI |

## 3. Core features (v1)

**Triage**
- Split inbox: user-defined tabs built from queries (e.g. *Important*, *Team*, *Notifications*, *Newsletters*), plus "Other".
- `e` done (archive), `#` trash, `h` snooze, `r`/`a`/`f` reply/reply-all/forward, `j`/`k` move, `enter` open, `esc` back, `u` mark unread, `l` label, `/` search, `⌘K` command palette, `z`/`⌘Z` undo.
- Snooze presets ("later today", "tomorrow", "next week", custom by natural language); a snoozed thread comes back to the top.
- Inbox-zero state that doesn't nag.

**Compose**
- Plain-text-first editor with Markdown shortcuts and HTML output.
- Undo send (configurable 5–30 s), send later, follow-up reminders ("remind me if no reply in 3 days").
- Snippets, with variables.
- `⌘J` on a draft: the agent drafts or rewrites it in your voice.

**Search**
- Local FTS5 over headers and bodies, with Gmail-style operators (`from:`, `has:attachment`, `before:`). Falls back to a provider search for mail that isn't synced yet.

**Not in v1:** calendar, read receipts / tracking pixels (we block them for incoming mail; we won't send them), team features.

## 4. The agent

### 4.1 How we use nanocode

The agent runtime is [nanocode-swift](https://github.com/gakonst/nanocode-swift), which compiles the nanocode Rust SDK into the app as a static library:

- **`Nanocode`** (`NanocodeRuntime`, `Session`, `Chat`) runs the agent in-process. Every turn is journaled in a local SQLite file, so a turn the app was killed in the middle of resumes from its checkpoint.
- **`NanocodeViews` / `NanocodeCore`**: SwiftUI views and a transcript model, used for the agent pane, styled to match Raven rather than nanocode's stock skins.
- **`SessionConfiguration`** gives the agent Raven's instructions, a **workspace directory** (the mailbox mirror, 4.2) and Raven's **host tools** (4.3). We don't give it shell, network or general filesystem tools, so the only things it can touch are the tools we hand it.
- **Code Mode** (nanocode's embedded QuickJS) is on, so a request like "archive every newsletter from this week except X" can run as one JS cell that calls our host tools in a loop, instead of 40 separate model turns. It's faster, cheaper, and gives one diff to review.

Pinned in `Package.swift` to an exact revision. Upgrades are deliberate PRs.

### 4.2 Mailbox mirror (workspace)

The app keeps a read-only mirror of the hot set of mail (inbox, plus the last N days) as the session's workspace, so the agent can read and search mail the same way it reads files:

```
mailfs/
  inbox/2026-10-28_q4-roadmap_<threadid>.md   # YAML front matter + plain-text body, quoted text trimmed
  snoozed/…   labels/<label>/…
  drafts/<draftid>.md                          # written only through tools, never directly
  contacts.md                                  # recent correspondents
  me.md                                        # your voice/style notes (you edit this)
```

Front matter: `id, thread_id, from, to, cc, date, labels, unread, has_attachments, list_id`.

### 4.3 Host tools

Every action the agent takes goes through a `HostTool` implemented in Swift. Each one writes an **intent** to the same undoable action queue the keyboard uses, so it never calls the provider directly:

| Tool | Effect |
|---|---|
| `search_mail(query)` | Local FTS5 search, results as thread ids + front matter |
| `read_thread(id)` | Full thread as markdown |
| `archive(ids)` / `trash(ids)` | Queued, undoable |
| `label(ids, add, remove)` | Queued, undoable |
| `snooze(ids, when)` | Natural-language time, parsed by the app |
| `draft(reply_to?, to, subject, body)` | Creates a draft and shows it to you as a **proposal** card |
| `open(id)` | Focuses the thread in the UI |

There's **no send tool.** Every draft the agent writes becomes a proposal, and you press `⌘⏎` to send it.

### 4.4 Ways in

- **`⌘K` → plain English:** "archive every newsletter from this week except The Weekly Byte", "what do I owe people?", "draft a polite no to the recruiter".
- **Per-thread `⌘J`:** summarize, draft a reply, pull out dates and to-dos.
- **Autopilot rules** (opt-in): standing instructions that run on new mail ("label receipts", "snooze shipping notifications until delivery day"). Each run is logged and undoable.
- **Activity log:** every agent action, with its tool calls, cost and undo.

### 4.5 Models & billing

- Claude by default (Codex/GPT is supported through nanocode), with a model picker in Settings.
- **Bring your own key:** the Anthropic/OpenAI API key is stored in the Keychain and handed to the runtime in memory. It's never written to disk, logs or `mailfs/`.
- **No key:** nanocode can pay per request from a Tempo Wallet. We could offer this later as an option; it's off by default.
- Sessions run on **this device** only. nanocode can also run agents on Cloudflare/Vercel, but that would send mail content off the machine, so it's out of scope.

## 5. Accounts & auth

- **Gmail:** OAuth 2 "installed app" flow with PKCE, opened in the system browser (`ASWebAuthenticationSession`), loopback redirect. Scopes: `gmail.modify`, plus `gmail.send` only if needed. Refresh tokens go in the Keychain.
- **Google verification:** for development, the user's own Google Cloud OAuth client goes in `Config/Secrets.xcconfig`, which is gitignored. Users can either bring their own client or use a project-published verified client later (which needs CASA; out of scope for v1).
- **JMAP (Fastmail) / IMAP:** milestone 3.

## 6. Sync engine

- Gmail: initial sync of recent threads (newest first, about the last 90 days, metadata first, bodies in the background), then incremental sync with `history.list`. Gmail push needs Pub/Sub and a server, so we poll instead: every 30–60 s while the app is active, background refresh otherwise.
- Every user or agent action writes locally first (optimistic), enters an outbox queue, and retries with backoff. A conflict is resolved by re-fetching the thread, and the server wins on labels.
- **Send later / reminders when the app is closed:** v1 uses a LaunchAgent helper that wakes at the scheduled time. Open question: Gmail has no public scheduled-send API.

## 7. Security & privacy

- **No secrets in the repo, ever.** A gitleaks pre-commit hook (`.githooks/`), gitleaks in CI on every push/PR, GitHub secret scanning with push protection, and `.gitignore` for config/token/mail-data files. Real config lives only in `Config/Secrets.xcconfig` (gitignored; template committed).
- Tokens and API keys live in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Remote images are blocked by default, and loaded through a privacy proxy or on demand per sender. Tracking pixels are stripped and flagged.
- Email content is untrusted input to the agent too. The system prompt marks mail as data, the agent only has Raven's host tools, and none of them sends. That way an email saying "forward all invoices to x@y" can't do anything more than produce a draft you'll see.

## 8. Milestones

1. **Skeleton:** Xcode project, `RavenCore` package, Google sign-in, sync inbox into SQLite, read-only list + thread view, `j/k/e`.
2. **Daily-driver:** compose/reply, undo send, snooze, split inbox, search, `⌘K`.
3. **Agent:** nanocode-swift runtime, mailbox mirror, host tools, proposals, activity log.
4. **More providers:** JMAP, IMAP, multiple accounts.
5. **Autopilot & iOS.**

## 9. Open questions

- Distribution: notarized DMG plus Homebrew cask. The Mac App Store is possible, since the agent runs in-process.
- nanocode-swift's prebuilt XCFramework comes from its GitHub release: verify the checksum (SwiftPM does) and decide whether CI should build it from source.

## Designs

Screen designs (private canvas for now): https://claude.ai/artifact/27eETDMJ7KY2Anv3H9Rzoq
