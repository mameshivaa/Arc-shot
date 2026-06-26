import AppKit
import Observation

@MainActor
final class MenuBarController: NSObject {
  private enum MenuBarText {
    static let idleTitle = "ArcShot"
    static let recordingPrefix = "REC"
  }

  private weak var coordinator: RecordingCoordinator?
  private weak var languageStore: AppLanguageStore?
  private var statusItem: NSStatusItem?

  func bind(to coordinator: RecordingCoordinator, languageStore: AppLanguageStore) {
    self.coordinator = coordinator
    self.languageStore = languageStore
    installStatusItemIfNeeded()
    refreshMenu(for: coordinator.state, elapsedSeconds: coordinator.recordingElapsedSeconds)
    observeCoordinator()
  }

  private func observeCoordinator() {
    guard let coordinator else { return }
    withObservationTracking {
      _ = coordinator.state
      _ = coordinator.recordingElapsedSeconds
      _ = languageStore?.language
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let coordinator = self.coordinator else { return }
        self.statusItem?.menu = self.makeMenu()
        self.refreshMenu(for: coordinator.state, elapsedSeconds: coordinator.recordingElapsedSeconds)
        self.observeCoordinator()
      }
    }
  }

  private func installStatusItemIfNeeded() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = MenuBarText.idleTitle
    item.menu = makeMenu()
    statusItem = item
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "ArcShot", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())

    let launcherItem = NSMenuItem(title: text("録画ランチャーを前面へ"), action: #selector(showRecordingLauncher), keyEquivalent: "l")
    launcherItem.target = self
    launcherItem.keyEquivalentModifierMask = [.command, .shift]
    launcherItem.tag = 1003
    menu.addItem(launcherItem)

    let workspaceItem = NSMenuItem(title: text("ArcShotウィンドウを表示"), action: #selector(showWorkspaceWindow), keyEquivalent: "o")
    workspaceItem.target = self
    workspaceItem.keyEquivalentModifierMask = [.command, .shift]
    workspaceItem.tag = 1004
    menu.addItem(workspaceItem)

    menu.addItem(.separator())

    let stopItem = NSMenuItem(title: text("録画を停止"), action: #selector(stopRecording), keyEquivalent: "")
    stopItem.target = self
    stopItem.tag = 1001
    menu.addItem(stopItem)

    let discardItem = NSMenuItem(title: text("録画を破棄"), action: #selector(discardRecording), keyEquivalent: "")
    discardItem.target = self
    discardItem.tag = 1002
    menu.addItem(discardItem)

    menu.addItem(.separator())
    let openItem = NSMenuItem(title: text("ArcShot を開く"), action: #selector(openApp), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)
    return menu
  }

  private func refreshMenu(for state: RecordingState, elapsedSeconds: Double) {
    guard let statusItem else { return }
    let elapsedLabel = Self.formatElapsed(elapsedSeconds)

    switch state {
    case .recording, .armed:
      statusItem.button?.title = "\(MenuBarText.recordingPrefix) \(elapsedLabel)"
    default:
      statusItem.button?.title = MenuBarText.idleTitle
    }

    if let menu = statusItem.menu {
      menu.item(at: 0)?.title = state == .recording || state == .armed
        ? "\(text("録画中")) \(elapsedLabel)"
        : text("待機中")
      let canStop = state == .recording || state == .armed
      menu.items.first(where: { $0.tag == 1001 })?.isEnabled = canStop
      menu.items.first(where: { $0.tag == 1002 })?.isEnabled = canStop
      menu.items.first(where: { $0.tag == 1004 })?.isEnabled = ArcShotRuntime.shared.projectStore.current != nil
    }
  }

  @objc private func stopRecording() {
    guard let coordinator else { return }
    Task { await coordinator.stopRecording() }
  }

  @objc private func discardRecording() {
    guard let coordinator else { return }
    Task { await coordinator.discardRecording() }
  }

  @objc private func openApp() {
    ArcShotRuntime.shared.handleUserReopen()
  }

  @objc private func showRecordingLauncher() {
    coordinator?.setFloatingLauncherVisible(true)
    MainWorkspaceWindow.orderOutKeyedMainWindow()
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func showWorkspaceWindow() {
    guard ArcShotRuntime.shared.projectStore.current != nil else {
      showRecordingLauncher()
      return
    }
    MainWorkspaceWindow.showKeyedMainWindow()
  }

  private static func formatElapsed(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let minutes = total / 60
    let secs = total % 60
    return String(format: "%02d:%02d", minutes, secs)
  }

  private func text(_ key: String) -> String {
    languageStore?.localized(key) ?? key
  }
}
