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
        IconButton(systemName: "checkmark", label: "Mark done (E)") { Task { await model.archive() } }
        IconButton(systemName: "clock", label: "Snooze (H)") { model.isSnoozePickerOpen = true }
        IconButton(systemName: "envelope.badge", label: "Mark unread (U)") { Task { await model.toggleRead() } }
        IconButton(systemName: "trash", label: "Trash (#)") { Task { await model.trash() } }
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      Divider().overlay(Theme.hairline)

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
            } else {
              CollapsedMessage(message: message)
                .onTapGesture { expanded.insert(message.id) }
            }
          }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
      }
    }
    .onChange(of: model.openThread?.id) { expanded = [] }
  }

  /// The newest message and any unread ones start open; earlier ones collapse to a line.
  private func isExpanded(_ message: Message) -> Bool {
    message.id == model.openMessages.last?.id || message.isUnread || expanded.contains(message.id)
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
    .background(Color(hex: 0xFAFAFB), in: RoundedRectangle(cornerRadius: 12))
    .contentShape(Rectangle())
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

  func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    config.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    BlockRemoteContent.install(on: config.userContentController) {
      view.loadHTMLString(html, baseURL: nil)
    }
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {}

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 600, height: height)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var height: Binding<CGFloat>
    init(height: Binding<CGFloat>) { self.height = height }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
        if let h = value as? CGFloat { DispatchQueue.main.async { self.height.wrappedValue = h } }
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
