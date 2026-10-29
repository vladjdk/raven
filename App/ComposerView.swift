import RavenCore
import SwiftUI

/// Writing an email. Replies sit inline at the bottom of the thread; new mail floats over the inbox.
struct ComposerView: View {
  @Environment(AppModel.self) private var model
  @Binding var draft: Draft
  var inline: Bool

  @State private var toText = ""
  @State private var ccText = ""
  @State private var showCc = false
  @FocusState private var focus: Field?

  enum Field { case to, cc, subject, body }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      VStack(spacing: 0) {
        AddressField(label: "To", text: $toText, focus: $focus, field: .to) {
          if !showCc {
            Button("Cc") { withAnimation(Motion.state) { showCc = true }; focus = .cc }
              .buttonStyle(.plain)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Theme.tertiary)
          }
        }
        if showCc {
          AddressField(label: "Cc", text: $ccText, focus: $focus, field: .cc) { EmptyView() }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if draft.kind == .new || draft.kind == .forward {
          HStack {
            TextField("Subject", text: $draft.subject)
              .textFieldStyle(.plain)
              .font(.system(size: 14, weight: .semibold))
              .focused($focus, equals: .subject)
          }
          .padding(.horizontal, 16)
          .frame(height: 38)
          Divider().overlay(Theme.hairline)
        }
      }

      ZStack(alignment: .topLeading) {
        if draft.body.isEmpty {
          Text(placeholder)
            .font(.system(size: 14))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .allowsHitTesting(false)
        }
        TextEditor(text: $draft.body)
          .font(.system(size: 14))
          .lineSpacing(4)
          .scrollContentBackground(.hidden)
          .scrollIndicators(.never)
          .focused($focus, equals: .body)
          .padding(.horizontal, 11)
          .padding(.top, 8)
      }
      .frame(minHeight: inline ? 120 : 220, maxHeight: inline ? 260 : .infinity)

      if let quoted = draft.quoted {
        Text(draft.kind == .forward ? "Forwarding \(quoted.from.displayName)'s message" : "Replying to \(quoted.from.displayName)")
          .font(.system(size: 12))
          .foregroundStyle(Theme.tertiary)
          .padding(.horizontal, 16)
          .padding(.bottom, 6)
      }

      toolbar
    }
    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
    .shadow(color: Theme.accent.opacity(0.10), radius: 14, y: 6)
    .onAppear {
      toText = draft.to.map(\.headerValueForEditing).joined(separator: ", ")
      ccText = draft.cc.map(\.headerValueForEditing).joined(separator: ", ")
      showCc = !draft.cc.isEmpty
      focus = draft.to.isEmpty ? .to : (draft.kind == .new && draft.subject.isEmpty ? .subject : .body)
    }
    .onChange(of: toText) { draft.to = MIME.addresses(toText) }
    .onChange(of: ccText) { draft.cc = MIME.addresses(ccText) }
    .onKeyPress(.escape) {
      model.closeComposer()
      return .handled
    }
  }

  private var placeholder: String {
    switch draft.kind {
    case .new: "Write your message…"
    case .reply, .replyAll: "Write your reply…"
    case .forward: "Add a note (optional)…"
    }
  }

  private var title: String {
    switch draft.kind {
    case .new: "New message"
    case .reply: "Reply"
    case .replyAll: "Reply all"
    case .forward: "Forward"
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: draft.kind == .forward ? "arrowshape.turn.up.right" : (draft.kind == .new ? "square.and.pencil" : "arrowshape.turn.up.left"))
        .font(.system(size: 12, weight: .medium))
      Text(title).font(.system(size: 12, weight: .semibold))
      Spacer()
      Button {
        model.closeComposer()
      } label: {
        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .help("Close (Esc). Your text is kept.")
      .accessibilityLabel("Close composer")
    }
    .foregroundStyle(Theme.tertiary)
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      IconButton(systemName: "trash", label: "Discard draft") { model.discardDraft() }
      Spacer()
      if !draft.canSend && !(draft.to + draft.cc).isEmpty {
        Text("Fix the address in To or Cc").font(.system(size: 12)).foregroundStyle(Color(hex: 0xB45309))
          .transition(.opacity)
      }
      Button(action: model.send) {
        HStack(spacing: 10) {
          Text("Send")
          Text("⌘⏎")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 34)
      }
      .buttonStyle(PrimaryButtonStyle())
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!draft.canSend)
      .opacity(draft.canSend ? 1 : 0.45)
      .animation(Motion.state, value: draft.canSend)
      .help("Send. You'll have \(Int(AppModel.undoSendSeconds)) seconds to undo.")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
  }
}

private struct AddressField<Accessory: View>: View {
  let label: String
  @Binding var text: String
  var focus: FocusState<ComposerView.Field?>.Binding
  let field: ComposerView.Field
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.system(size: 13))
        .foregroundStyle(Theme.tertiary)
        .frame(width: 24, alignment: .leading)
      TextField("name@example.com", text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused(focus, equals: field)
      accessory()
    }
    .padding(.horizontal, 16)
    .frame(height: 36)
    .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
  }
}

extension Address {
  /// How an address reads in an editable To field.
  var headerValueForEditing: String {
    guard let name, !name.isEmpty else { return email }
    return name.contains(",") ? "\"\(name)\" <\(email)>" : "\(name) <\(email)>"
  }
}
