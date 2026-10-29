import RavenCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var apiKey = ""
  @State private var saved = false
  @AppStorage("showShortcutHints") private var showHints = true

  var body: some View {
    Form {
      Section("Account") {
        LabeledContent("Signed in as", value: model.account ?? "Not signed in")
        if model.phase == .ready {
          Button("Sign out", role: .destructive) { Task { await model.signOut() } }
        }
      }
      Section {
        SecureField("sk-ant-…", text: $apiKey)
          .textContentType(.password)
        HStack {
          Button("Save key") {
            try? model.keychain.set(Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8), for: Assistant.keychainAccount)
            apiKey = ""
            withAnimation(.snappy) { saved = true }
          }
          .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
          if model.assistant.hasAPIKey {
            Button("Remove key") {
              try? model.keychain.delete(Assistant.keychainAccount)
              saved = false
            }
          }
          Spacer()
          if saved || model.assistant.hasAPIKey {
            Label("Stored in your Keychain", systemImage: "lock.fill")
              .font(.callout)
              .foregroundStyle(.secondary)
              .transition(.opacity)
          }
        }
      } header: {
        Text("Plain-English requests")
      } footer: {
        Text("Type something like “archive this week's newsletters” in ⌘K and choose Do this. Requests use your Anthropic API key, can only search, sort and draft (never send), and one Undo reverts everything they changed.")
          .foregroundStyle(.secondary)
      }
      Section("Help") {
        Toggle("Show keyboard hints at the bottom of the inbox", isOn: $showHints)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
  }
}
