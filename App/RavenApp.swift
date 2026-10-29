import RavenCore
import SwiftUI

@main
struct RavenApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .frame(minWidth: 860, minHeight: 560)
        .task { await model.start() }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1280, height: 800)
    .commands {
      CommandGroup(replacing: .undoRedo) {
        Button("Undo") { Task { await model.undo() } }
          .keyboardShortcut("z")
      }
      CommandMenu("Mail") {
        Button("Command Palette") { model.isPaletteOpen.toggle() }
          .keyboardShortcut("k")
        Button("Refresh") { Task { await model.syncNow() } }
          .keyboardShortcut("r")
          .disabled(model.isDemo)
        Divider()
        Button("Sign Out") { Task { await model.signOut() } }
          .disabled(model.phase != .ready)
      }
    }
  }
}

struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      Theme.window.ignoresSafeArea()
      switch model.phase {
      case .launching:
        ProgressView().controlSize(.small)
      case .signedOut, .signingIn:
        SignInView()
      case .ready:
        MainView()
      }
    }
    .foregroundStyle(Theme.ink)
    .preferredColorScheme(.light)
  }
}
