#if DEBUG
  import AppKit
  import RavenCore
  import SwiftUI

  /// `Raven --snapshot <dir>` renders the main screens with sample mail to PNGs and quits.
  /// Used to check layout without a visible window (CI, locked screen).
  @MainActor
  enum SnapshotRunner {
    static var outputDirectory: URL? {
      let args = CommandLine.arguments
      guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return nil }
      // The app is sandboxed: snapshots go to its container temp folder under the given name.
      return FileManager.default.temporaryDirectory.appendingPathComponent(args[i + 1], isDirectory: true)
    }

    static func run(model: AppModel, into dir: URL) async {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      await model.startDemo()
      try? await Task.sleep(for: .milliseconds(300))

      // A real (offscreen, never shown) window, so scroll views and AppKit controls draw too.
      let host = NSHostingView(rootView: AnyView(
        ZStack { Theme.window; MainView() }.environment(model).preferredColorScheme(.light)))
      let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      window.orderBack(nil)

      func shot(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(450))  // Let animations settle.
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
      }

      await shot("1-inbox")
      model.select(tab: .newsletters)
      await shot("2-newsletters-tab")
      model.select(tab: .important)
      await model.openSelected()
      await shot("3-thread")
      model.reply(all: false)
      model.draft?.body = "Hi Priya, 2pm Thursday works. A — sync first."
      await shot("4-reply")
      model.discardDraft()
      model.closeThread()
      model.isPaletteOpen = true
      await shot("5-palette")
      model.isPaletteOpen = false
      model.isSnoozePickerOpen = true
      await shot("6-snooze")
      model.isSnoozePickerOpen = false
      model.compose()
      await shot("7-compose")
      model.discardDraft()
      await model.primaryAction()
      await shot("8-after-done-toast")
      model.go(to: .snoozed)
      try? await Task.sleep(for: .milliseconds(300))
      await shot("9-empty-snoozed")
      NSApp.terminate(nil)
    }
  }
#endif
