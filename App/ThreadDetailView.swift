import RavenCore
import SwiftUI
import WebKit

struct ThreadDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var expanded: Set<String> = []

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        IconButton(systemName: "chevron.left", label: "Back (Esc)") { model.closeThread() }
        Spacer()
        IconButton(systemName: "arrowshape.turn.up.left", label: "Reply (R)") { model.reply(all: false) }
        IconButton(systemName: "arrowshape.turn.up.left.2", label: "Reply all (A)") { model.reply(all: true) }
        IconButton(systemName: "arrowshape.turn.up.right", label: "Forward (F)") { model.forward() }
        Divider().frame(height: 18).padding(.horizontal, 6)
        let primary = model.primaryActionTitle(for: model.openThread)
        IconButton(systemName: primary.systemImage, label: primary.title == "Mark done" ? "Mark done (E): moves it out of the Inbox" : "\(primary.title) (E)") {
          Task { await model.primaryAction() }
        }
        IconButton(systemName: "clock", label: "Snooze (H)") { model.isSnoozePickerOpen = true }
        IconButton(
          systemName: model.openThread?.isUnread == true ? "envelope.open" : "envelope.badge",
          label: model.openThread?.isUnread == true ? "Mark as read (U)" : "Mark as unread (U)"
        ) { Task { await model.toggleRead() } }
        IconButton(systemName: "trash", label: "Move to Trash (#)") { Task { await model.trash() } }
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      Divider().overlay(Theme.hairline)
      if let error = model.errorMessage {
        ErrorBanner(message: error).transition(.move(edge: .top).combined(with: .opacity))
      }

      ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let thread = model.openThread {
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 6) {
                Chip(text: InboxTab.classify(thread).title, prominent: true)
                if thread.messageCount > 1 { Chip(text: "\(thread.messageCount) messages", prominent: false) }
              }
              Text(thread.subject)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.4)
                .textSelection(.enabled)
            }
          }
          ForEach(model.openMessages) { message in
            if isExpanded(message) {
              MessageCard(message: message)
                .transition(.opacity)
            } else {
              CollapsedMessage(message: message)
                .onTapGesture { withAnimation(Motion.state) { _ = expanded.insert(message.id) } }
                .help("Show this message")
            }
          }

          if let draft = model.draft, model.showsInlineComposer {
            ComposerView(draft: Binding(get: { model.draft ?? draft }, set: { model.draft = $0 }), inline: true)
              .id(draft.id)
              .transition(.move(edge: .bottom).combined(with: .opacity))
              .onAppear { withAnimation(Motion.panel) { proxy.scrollTo("composer", anchor: .bottom) } }
          } else {
            ReplyBar()
              .transition(.opacity)
          }
          Color.clear.frame(height: 1).id("composer")
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
      }
      // Each thread starts at the top rather than at the last one's scroll offset.
      .id(model.openThread?.id)
      }
    }
    .animation(Motion.state, value: model.errorMessage)
    .onChange(of: model.openThread?.id, initial: true) {
      // Decide once, on open, which messages start expanded; marking read must not collapse them.
      expanded = Set(model.openMessages.filter(\.isUnread).map(\.id))
    }
  }

  /// The newest message and any that were unread when opened start open; earlier ones collapse.
  private func isExpanded(_ message: Message) -> Bool {
    message.id == model.openMessages.last?.id || expanded.contains(message.id)
  }
}

/// The quiet "Reply / Reply all / Forward" row under a thread, so replying is obvious.
struct ReplyBar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 8) {
      ReplyButton(title: "Reply", key: "R", systemImage: "arrowshape.turn.up.left") { model.reply(all: false) }
      if (model.openMessages.last.map { $0.to.count + $0.cc.count } ?? 0) > 1 {
        ReplyButton(title: "Reply all", key: "A", systemImage: "arrowshape.turn.up.left.2") { model.reply(all: true) }
      }
      ReplyButton(title: "Forward", key: "F", systemImage: "arrowshape.turn.up.right") { model.forward() }
      Spacer()
    }
  }
}

struct ReplyButton: View {
  let title: String
  let key: String
  let systemImage: String
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
        Text(title).font(.system(size: 13, weight: .medium))
        KeyCap(label: key)
      }
      .foregroundStyle(Theme.ink)
      .padding(.leading, 14)
      .padding(.trailing, 8)
      .frame(height: 36)
      .background(hovered ? Theme.fill : .white, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
    .buttonStyle(PressableStyle())
    .onHover { h in withAnimation(Motion.hover) { hovered = h } }
  }
}

struct Chip: View {
  let text: String
  let prominent: Bool

  var body: some View {
    Text(text)
      .font(.system(size: 12, weight: prominent ? .semibold : .medium))
      .foregroundStyle(prominent ? Theme.accentInk : Theme.secondary)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .background(prominent ? Theme.accentSoft : Theme.fill, in: Capsule())
  }
}

struct CollapsedMessage: View {
  let message: Message
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 12) {
      Avatar(address: message.from, size: 28)
      (Text(message.from.displayName).fontWeight(.semibold).foregroundColor(Theme.ink)
        + Text("  ·  ") + Text(message.snippet))
        .lineLimit(1)
        .foregroundStyle(Theme.secondary)
      Spacer()
      Text(RowDate.format(message.date)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(hovered ? Theme.fill : Color(hex: 0xFAFAFB), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xEEEEF1)))
    .contentShape(Rectangle())
    .onHover { h in withAnimation(Motion.hover) { hovered = h } }
  }
}

struct MessageCard: View {
  let message: Message

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Avatar(address: message.from, size: 36)
        VStack(alignment: .leading, spacing: 1) {
          Text(message.from.displayName).font(.system(size: 14, weight: .semibold))
          Text(recipients).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        Spacer()
        Text(message.date.formatted(date: .abbreviated, time: .shortened))
          .font(.system(size: 12))
          .foregroundStyle(Theme.tertiary)
      }
      if let text = message.bodyText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(text)
          .font(.system(size: 14))
          .lineSpacing(4)
          .foregroundStyle(Color(hex: 0x27272A))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let html = message.bodyHTML {
        SafeHTMLView(html: html)
      } else {
        Text(message.snippet).foregroundStyle(Theme.secondary)
      }
      if !message.attachments.isEmpty {
        HStack(spacing: 8) {
          ForEach(message.attachments, id: \.self) { file in
            HStack(spacing: 6) {
              Image(systemName: "paperclip").font(.system(size: 11, weight: .semibold))
              Text(file.filename).lineLimit(1)
              Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
    .padding(20)
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xEEEEF1)))
  }

  private var recipients: String {
    let names = (message.to + message.cc).map(\.displayName)
    return names.isEmpty ? "" : "to " + names.joined(separator: ", ")
  }
}

/// Renders HTML mail with JavaScript off and every remote load blocked, so opening an email
/// can't run code or tell the sender you read it. Links open in the default browser.
struct SafeHTMLView: NSViewRepresentable {
  let html: String
  @State private var height: CGFloat = 120
  @State private var measured = false

  func makeCoordinator() -> Coordinator { Coordinator(height: $height, measured: $measured) }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    config.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: config)
    view.appearance = NSAppearance(named: .aqua)
    view.alphaValue = 0  // Revealed once measured, so it doesn't jump from a placeholder height.
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    BlockRemoteContent.install(on: config.userContentController) {
      view.loadHTMLString(html, baseURL: nil)
    }
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    if measured && view.alphaValue == 0 {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.2
        view.animator().alphaValue = 1
      }
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 600, height: height)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var height: Binding<CGFloat>
    var measured: Binding<Bool>
    init(height: Binding<CGFloat>, measured: Binding<Bool>) {
      self.height = height
      self.measured = measured
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
        DispatchQueue.main.async {
          if let h = value as? CGFloat { self.height.wrappedValue = h }
          self.measured.wrappedValue = true
        }
      }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      if action.navigationType == .linkActivated, let url = action.request.url,
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
      {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(action.navigationType == .other ? .allow : .cancel)
    }
  }
}

@MainActor
enum BlockRemoteContent {
  private static var compiled: WKContentRuleList?

  static func install(on controller: WKUserContentController, then load: @escaping @MainActor () -> Void) {
    if let compiled {
      controller.add(compiled)
      load()
      return
    }
    let rules = #"[{"trigger":{"url-filter":"^(https?|ftp|wss?)://"},"action":{"type":"block"}}]"#
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "raven-block-remote", encodedContentRuleList: rules) { list, _ in
      MainActor.assumeIsolated {
        if let list {
          compiled = list
          controller.add(list)
          load()
        }
        // If the rules fail to compile, show nothing rather than load unprotected.
      }
    }
  }
}
