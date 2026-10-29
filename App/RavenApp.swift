import AppKit
import RavenCore
import SwiftUI

@main
struct RavenApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .frame(minWidth: 900, minHeight: 560)
        .task {
          delegate.model = model
          #if DEBUG
            if SnapshotRunner.outputDirectory != nil { return }
          #endif
          await model.start()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1280, height: 800)
    .commands { RavenCommands(model: model) }

    Settings {
      SettingsView().environment(model)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor var model: AppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Every color is designed for light; keep Settings and web views light too until dark mode lands.
    NSApp.appearance = NSAppearance(named: .aqua)
    #if DEBUG
      if let dir = SnapshotRunner.outputDirectory {
        Task { @MainActor in await SnapshotRunner.run(model: AppModel(), into: dir) }
      }
    #endif
  }

  /// Never lose mail in the undo-send window: send it before quitting.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      guard let model, model.canUndo, model.undoTitle == "Undo Send" else { return .terminateNow }
      Task { @MainActor in
        await model.flushPendingSend()
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
  }
}

/// The menu bar: every action has a menu item, so nothing depends on knowing the shortcuts.
struct RavenCommands: Commands {
  let model: AppModel

  /// True when a text field or editor has keyboard focus, so ⌘Z edits text instead of mail.
  @MainActor private var isEditingText: Bool {
    NSApp.keyWindow?.firstResponder is NSText
  }

  var body: some Commands {
    CommandGroup(replacing: .undoRedo) {
      Button(model.canUndo ? model.undoTitle : "Undo") {
        if isEditingText {
          NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else {
          Task { await model.undo() }
        }
      }
      .keyboardShortcut("z")
      Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }
    CommandGroup(after: .newItem) {
      Button("New Message") { model.compose() }
        .keyboardShortcut("n")
        .disabled(model.phase != .ready)
    }
    CommandGroup(after: .textEditing) {
      Button("Find in Mail") { model.focusSearch() }
        .keyboardShortcut("f")
        .disabled(model.phase != .ready)
    }
    CommandMenu("Message") {
      let ready = model.phase == .ready
      let target = model.targetThread
      Button("Reply  (R)") { withThread { model.reply(all: false) } }.disabled(!ready || target == nil)
      Button("Reply All  (A)") { withThread { model.reply(all: true) } }.disabled(!ready || target == nil)
      Button("Forward  (F)") { withThread { model.forward() } }.disabled(!ready || target == nil)
      Divider()
      Button("\(model.primaryActionTitle(for: target).title)  (E)") { Task { await model.primaryAction() } }
        .disabled(!ready || target == nil)
      Button("Snooze…  (H)") { model.isSnoozePickerOpen = true }.disabled(!ready || target == nil)
      Button(target?.isUnread == true ? "Mark as Read  (U)" : "Mark as Unread  (U)") { Task { await model.toggleRead() } }
        .disabled(!ready || target == nil)
      Button("Move to Trash  (#)") { Task { await model.trash() } }.disabled(!ready || target == nil)
      Divider()
      Button("Command Palette…") { model.isPaletteOpen.toggle() }
        .keyboardShortcut("k")
        .disabled(!ready)
    }
    CommandMenu("Go") {
      ForEach(Array(Mailbox.allCases.enumerated()), id: \.element) { index, box in
        Button(box.title) { model.go(to: box) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
          .disabled(model.phase != .ready)
      }
      Divider()
      Button("Refresh") { Task { await model.syncNow() } }
        .keyboardShortcut("r")
        .disabled(model.isDemo || model.phase != .ready)
      Button(model.isDemo ? "Leave Sample Mailbox" : "Sign Out…") { model.requestSignOut() }
        .disabled(model.phase != .ready)
    }
  }

  /// Reply/forward need the thread's messages, so open it first when acting from the list.
  @MainActor private func withThread(_ body: @escaping @MainActor () -> Void) {
    Task {
      if model.openThread == nil { await model.openSelected() }
      body()
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
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
      case .ready:
        MainView()
          .transition(.opacity)
      }
    }
    .foregroundStyle(Theme.ink)
    .preferredColorScheme(.light)
  }
}
