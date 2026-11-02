import Nanocode
import RavenCore
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      AccountsSettings()
        .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
      RequestsSettings()
        .tabItem { Label("Requests", systemImage: "bolt") }
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
    }
    .frame(width: 520)
  }
}

struct AccountsSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        if model.sessions.isEmpty {
          Text("Not signed in").foregroundStyle(.secondary)
        }
        ForEach(model.sessions, id: \.email) { session in
          HStack(spacing: 10) {
            Text(String(session.email.prefix(1)).uppercased())
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Theme.avatar(for: session.email).foreground)
              .frame(width: 24, height: 24)
              .background(Theme.avatar(for: session.email).background, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
              Text(session.email)
              if session.needsReauth {
                Text("Sign-in expired").font(.caption).foregroundStyle(.orange)
              }
            }
            Spacer()
            if session.needsReauth {
              Button("Sign In Again") { model.signIn(as: session.email) }
            }
            Button("Sign Out…") {
              Task {
                await model.switchAccount(to: session.email)
                model.requestSignOut()
              }
            }
          }
        }
        Button {
          model.signIn()
        } label: {
          Label(model.isAddingAccount ? "Waiting for your browser…" : "Add Gmail Account…", systemImage: "plus")
        }
        .disabled(model.oauth == nil || model.isAddingAccount || model.phase != .ready)
      } header: {
        Text("Gmail accounts")
      } footer: {
        Text("Switch accounts from the sidebar or with ⌃⌘1–9. Each account's mail is stored separately on this Mac.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// Plain-English requests in ⌘K: which service runs them, how you sign in, and what it knows about you.
struct RequestsSettings: View {
  @Environment(AppModel.self) private var model
  @State private var code = ""
  @State private var keyText = ""

  var body: some View {
    @Bindable var assistant = model.assistant
    let service = assistant.settings.service
    Form {
      Section {
        Picker("Service", selection: $assistant.settings.service) {
          ForEach(AssistantSettings.Service.allCases) { Text($0.name).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: assistant.settings.service) { assistant.settings.model = nil }
        Picker("Sign in with", selection: $assistant.settings.access) {
          Text("\(service.name) subscription").tag(AssistantSettings.Access.plan)
          Text("API key").tag(AssistantSettings.Access.apiKey)
        }
        switch assistant.settings.access {
        case .plan: PlanSignInRow(service: service, code: $code)
        case .apiKey: keyRow(service)
        }
      } header: {
        Text("Plain-English requests")
      } footer: {
        Text("Type something like “archive this week's newsletters” in ⌘K and choose Do this. Requests can search, sort and draft replies, but never send, and one Undo reverts everything they changed.")
          .foregroundStyle(.secondary)
      }

      Section {
        let models = assistant.catalog[service.provider] ?? []
        Picker("Model", selection: Binding(
          get: { assistant.settings.resolvedModel },
          set: { assistant.settings.model = $0 == service.defaultModel ? nil : $0 })) {
          if !models.contains(where: { $0.id == service.defaultModel }) {
            Text(service.defaultModel).tag(service.defaultModel)
          }
          ForEach(models) { Text($0.name).tag($0.id) }
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("About you")
          TextEditor(text: $assistant.settings.notes)
            .font(.body)
            .frame(height: 70)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.08)))
          Text("Given to every request, e.g. “I'm in New York. Dana is my manager. Keep replies short.”")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Context")
      }

      Section {
        LabeledContent("Stored in") {
          HStack {
            Text(Assistant.folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
              .font(.caption.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Button("Show in Finder") { assistant.revealFolder() }
          }
        }
      } footer: {
        Text("Settings and request history stay on this Mac. Sign-ins and keys are kept in your Keychain.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .fixedSize(horizontal: false, vertical: true)
    .task { await assistant.prepare() }
    .animation(Motion.state, value: assistant.settings)
  }

  @ViewBuilder private func keyRow(_ service: AssistantSettings.Service) -> some View {
    let assistant = model.assistant
    if assistant.apiKey(for: service) != nil {
      LabeledContent("\(service.name) API key") {
        HStack {
          Label("In your Keychain", systemImage: "lock.fill").foregroundStyle(.secondary)
          Button("Remove") { assistant.setAPIKey(nil, for: service) }
        }
      }
    } else {
      HStack {
        SecureField("\(service.name) API key", text: $keyText, prompt: Text(service.keyPlaceholder))
          .textContentType(.password)
        Button("Save") {
          assistant.setAPIKey(keyText.trimmingCharacters(in: .whitespacesAndNewlines), for: service)
          keyText = ""
        }
        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }
}

/// Signs in with a Claude or ChatGPT subscription through nanocode.
/// Claude opens a page that shows a code to paste back; ChatGPT shows a code to enter on its page.
struct PlanSignInRow: View {
  @Environment(AppModel.self) private var model
  let service: AssistantSettings.Service
  @Binding var code: String

  var body: some View {
    let provider = service.provider
    if let plans = model.assistant.plans {
      VStack(alignment: .leading, spacing: 10) {
        if plans.isSignedIn(provider) {
          HStack {
            Label("Signed in to \(service.name)", systemImage: "checkmark.circle.fill")
              .foregroundStyle(Theme.success)
            Spacer()
            Button("Sign Out") { Task { await plans.signOut(provider) } }
          }
        } else if let signIn = plans.signIns[provider] {
          switch signIn.step {
          case .enterCode(let url, let userCode):
            Text("Enter this code on the ChatGPT page that opened:").foregroundStyle(.secondary)
            Text(userCode)
              .font(.system(size: 24, weight: .bold, design: .monospaced))
              .textSelection(.enabled)
            HStack {
              Button("Copy Code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(userCode, forType: .string)
              }
              Button("Open Page Again") { NSWorkspace.shared.open(url) }
              Button("Cancel") { plans.cancel(provider) }
              Spacer()
              ProgressView().controlSize(.small)
              Text("Waiting…").foregroundStyle(.secondary)
            }
          case .openURL(let url):
            Text("Sign in on the Claude page that opened, then paste the code it shows.").foregroundStyle(.secondary)
            HStack {
              TextField("Code", text: $code)
                .font(.body.monospaced())
                .onSubmit { finish(plans) }
              Button(plans.busy.contains(provider) ? "Finishing…" : "Finish") { finish(plans) }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || plans.busy.contains(provider))
            }
            HStack {
              Button("Open Page Again") { NSWorkspace.shared.open(url) }
              Button("Cancel") { plans.cancel(provider) }
            }
          }
        } else {
          Button {
            Task {
              guard let signIn = await plans.signIn(provider) else { return }
              switch signIn.step {
              case .enterCode(let url, _), .openURL(let url): NSWorkspace.shared.open(url)
              }
            }
          } label: {
            Text(plans.busy.contains(provider) ? "Opening…" : "Sign in with \(service.name)")
              .frame(minWidth: 160)
          }
          .buttonStyle(.borderedProminent)
          .disabled(plans.busy.contains(provider))
          Text(service == .claude ? "Uses your Claude Pro or Max plan." : "Uses your ChatGPT Plus or Pro plan.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let error = plans.error {
          Text(error).font(.caption).foregroundStyle(Color(hex: 0xB91C1C))
        }
      }
      .animation(Motion.state, value: plans.isSignedIn(provider))
    } else {
      HStack {
        ProgressView().controlSize(.small)
        Text("Starting…").foregroundStyle(.secondary)
      }
    }
  }

  private func finish(_ plans: PlanMonitor) {
    let value = code
    Task {
      await plans.complete(service.provider, code: value)
      if plans.isSignedIn(service.provider) { code = "" }
    }
  }
}

struct GeneralSettings: View {
  @AppStorage("showShortcutHints") private var showHints = true

  var body: some View {
    Form {
      Section("Help") {
        Toggle("Show keyboard hints at the bottom of the inbox", isOn: $showHints)
      }
    }
    .formStyle(.grouped)
    .fixedSize(horizontal: false, vertical: true)
  }
}
