import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit
import SwiftUI

// MARK: - Runtime

@MainActor
final class ArcShotRuntime {
  static let shared = ArcShotRuntime()

  let projectStore = ProjectStore()
  let alertCenter = AppAlertCenter()
  let languageStore = AppLanguageStore()
  let workflowNavigator = WorkflowNavigator()
  let recordingCoordinator = RecordingCoordinator()
  let recordingSelection = RecordingSelectionModel()

  private let floatingRecordingLauncherController = FloatingRecordingLauncherController()
  private let menuBarController = MenuBarController()
  private let globalShortcutController = GlobalRecordingShortcutController()
  private let workspaceWindowController = MainWorkspaceWindowController()
  private let debugCaptureWindowController = DebugCaptureWindowController()

  private var didStart = false

  func start() {
    guard !didStart else { return }
    didStart = true

    floatingRecordingLauncherController.bind(
      coordinator: recordingCoordinator,
      selectionModel: recordingSelection,
      projectStore: projectStore,
      workflowNavigator: workflowNavigator,
      alertCenter: alertCenter
    )
    menuBarController.bind(to: recordingCoordinator, languageStore: languageStore)
    globalShortcutController.bind(to: recordingCoordinator)
    projectStore.refreshProjects()
    recordingCoordinator.setFloatingLauncherVisible(true)
  }

  func hideCaptureSurfacesForEditor() {
    recordingCoordinator.setFloatingLauncherVisible(false)
    floatingRecordingLauncherController.forceDismissForEditor()
  }

  func showWorkspace() {
    if projectStore.current != nil,
      recordingCoordinator.state != .recording,
      recordingCoordinator.state != .armed {
      hideCaptureSurfacesForEditor()
    }
    workspaceWindowController.show(
      projectStore: projectStore,
      alertCenter: alertCenter,
      languageStore: languageStore,
      workflowNavigator: workflowNavigator,
      recordingCoordinator: recordingCoordinator,
      recordingSelection: recordingSelection
    )
  }

  func hideWorkspace() {
    workspaceWindowController.hide()
  }

  func showDebugCaptureWindow() {
    #if DEBUG
    debugCaptureWindowController.show(
      projectStore: projectStore,
      alertCenter: alertCenter,
      languageStore: languageStore,
      workflowNavigator: workflowNavigator,
      recordingCoordinator: recordingCoordinator,
      recordingSelection: recordingSelection
    )
    #endif
  }

  func workspaceWindowForMarketingScreenshot() -> NSWindow? {
    workspaceWindowController.screenshotWindow
  }

  func recordingLauncherWindowForMarketingScreenshot() -> NSWindow? {
    floatingRecordingLauncherController.marketingScreenshotWindow()
  }

  func applyMarketingScreenshotFrame() {
    workspaceWindowController.applyMarketingScreenshotFrame()
  }

  func handleUserReopen() {
    if recordingCoordinator.state == .recording || recordingCoordinator.state == .armed || projectStore.current == nil {
      recordingCoordinator.setFloatingLauncherVisible(true)
      hideWorkspace()
    } else {
      hideCaptureSurfacesForEditor()
      workflowNavigator.sidebarTab = .edit
      showWorkspace()
    }
    NSApp.activate(ignoringOtherApps: true)
  }
}

// MARK: - Layout

enum AppUIMetrics {
  static let rootPadding: CGFloat = 24
  /// Between major stacks (detail title ↔ content).
  static let contentSpacing: CGFloat = 16
  /// Inside GroupBox / forms.
  static let groupSpacing: CGFloat = 12
  /// Tight stacks (caption blocks).
  static let tightSpacing: CGFloat = 10
}

// MARK: - Workflow navigation

enum WorkflowSidebarTab: String, CaseIterable, Identifiable {
  case capture
  case library
  case edit
  case export

  var id: String { rawValue }

  var title: String {
    switch self {
    case .capture: return "キャプチャ"
    case .library: return "ライブラリ"
    case .edit: return "編集"
    case .export: return "書き出し"
    }
  }

  var systemImage: String {
    switch self {
    case .capture: return "record.circle"
    case .library: return "folder"
    case .edit: return "wand.and.stars"
    case .export: return "square.and.arrow.up"
    }
  }

  var menuKeyEquivalent: KeyEquivalent {
    switch self {
    case .capture: return "1"
    case .library: return "4"
    case .edit: return "2"
    case .export: return "3"
    }
  }

  var isAvailableWithoutOpenProject: Bool {
    switch self {
    case .capture, .library:
      return true
    case .edit, .export:
      return false
    }
  }
}

@MainActor
@Observable
final class WorkflowNavigator {
  var sidebarTab: WorkflowSidebarTab = .capture
  var showingReviewShortcutsHelp = false
}

// MARK: - Main workspace NSWindow tagging / presentation

/// SwiftUI の `WindowGroup` から生成されるワークスペース用ウィンドウを特定する。
enum MainWorkspaceWindow {
  static let identifier = NSUserInterfaceItemIdentifier("ArcShot.MainWorkspace")

  /// フローティングランチャーから編集画面へ進んだあと、アプリウィンドウを前置する。
  @MainActor
  static func presentKey() {
    ArcShotRuntime.shared.showWorkspace()
  }

  /// 録画開始をフローティングバー中心にするとき、アプリウィンドウを前面から外す。
  @MainActor
  static func orderOutKeyedMainWindow() {
    ArcShotRuntime.shared.hideWorkspace()
  }

  /// ワークスペースを前面に復帰（メニューバー・アプリを開く 等）。
  @MainActor
  static func showKeyedMainWindow() {
    ArcShotRuntime.shared.showWorkspace()
  }
}

@MainActor
private final class MainWorkspaceWindowController {
  private var window: NSWindow?

  func show(
    projectStore: ProjectStore,
    alertCenter: AppAlertCenter,
    languageStore: AppLanguageStore,
    workflowNavigator: WorkflowNavigator,
    recordingCoordinator: RecordingCoordinator,
    recordingSelection: RecordingSelectionModel
  ) {
    if projectStore.current != nil, recordingCoordinator.state != .recording, recordingCoordinator.state != .armed {
      ArcShotRuntime.shared.hideCaptureSurfacesForEditor()
    }
    if window?.isVisible != true, workflowNavigator.sidebarTab != .library {
      workflowNavigator.sidebarTab = projectStore.current == nil ? .capture : .edit
    }
    let isEditorPresentation = projectStore.current != nil
    let win = window ?? makeWindow(
      projectStore: projectStore,
      alertCenter: alertCenter,
      languageStore: languageStore,
      workflowNavigator: workflowNavigator,
      recordingCoordinator: recordingCoordinator,
      recordingSelection: recordingSelection
    )
    let wasHidden = !win.isVisible
    window = win
    if isEditorPresentation {
      MainWorkspaceWindowLayout.applyPreferredEditorFrame(
        to: win,
        force: wasHidden || !MainWorkspaceWindowLayout.isUsableEditorFrame(win.frame, on: win.screen)
      )
    }
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
  }

  func hide() {
    window?.orderOut(nil)
  }

  func applyMarketingScreenshotFrame() {
    guard let window else { return }
    let size = NSSize(width: 1280, height: 800)
    let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.midY - size.height / 2
    )
    window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  var screenshotWindow: NSWindow? { window }

  private func makeWindow(
    projectStore: ProjectStore,
    alertCenter: AppAlertCenter,
    languageStore: AppLanguageStore,
    workflowNavigator: WorkflowNavigator,
    recordingCoordinator: RecordingCoordinator,
    recordingSelection: RecordingSelectionModel
  ) -> NSWindow {
    let root = AppLocalizedRoot {
      ContentView()
        .frame(minWidth: 1120, minHeight: 720)
        .environment(projectStore)
        .environment(alertCenter)
        .environment(workflowNavigator)
        .environment(recordingCoordinator)
        .environment(recordingSelection)
    }
    .environment(languageStore)
    let host = NSHostingController(rootView: root)
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    win.identifier = MainWorkspaceWindow.identifier
    win.title = "ArcShot"
    win.titleVisibility = .hidden
    win.titlebarAppearsTransparent = true
    win.isReleasedWhenClosed = false
    win.contentMinSize = MainWorkspaceWindowLayout.minimumContentSize
    win.contentViewController = host
    MainWorkspaceWindowLayout.applyPreferredEditorFrame(to: win, force: true)
    return win
  }
}

@MainActor
private enum MainWorkspaceWindowLayout {
  static let minimumContentSize = NSSize(width: 1280, height: 760)

  private static let idealEditorSize = NSSize(width: 1680, height: 1000)
  private static let screenMargin: CGFloat = 32

  static func applyPreferredEditorFrame(to window: NSWindow, force: Bool) {
    guard force else { return }
    let screen = targetScreen(for: window)
    window.setFrame(preferredEditorFrame(on: screen), display: false, animate: false)
  }

  static func isUsableEditorFrame(_ frame: NSRect, on currentScreen: NSScreen?) -> Bool {
    let screen = currentScreen ?? targetScreen(for: nil)
    let preferred = preferredEditorFrame(on: screen)
    let visibleFrame = screen.visibleFrame

    guard frame.intersects(visibleFrame) else { return false }
    guard frame.width >= preferred.width * 0.86, frame.height >= preferred.height * 0.86 else {
      return false
    }

    let xDrift = abs(frame.midX - preferred.midX)
    let yDrift = abs(frame.midY - preferred.midY)
    return xDrift <= visibleFrame.width * 0.18 && yDrift <= visibleFrame.height * 0.18
  }

  private static func preferredEditorFrame(on screen: NSScreen) -> NSRect {
    let visible = screen.visibleFrame
    let maxWidth = max(640, visible.width - screenMargin * 2)
    let maxHeight = max(520, visible.height - screenMargin * 2)
    let width = min(idealEditorSize.width, max(minimumContentSize.width, visible.width * 0.88), maxWidth)
    let height = min(idealEditorSize.height, max(minimumContentSize.height, visible.height * 0.86), maxHeight)
    let size = NSSize(width: width, height: height)

    let centeredOrigin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.midY - size.height / 2
    )
    return NSRect(origin: centeredOrigin, size: size)
  }

  private static func targetScreen(for window: NSWindow?) -> NSScreen {
    let mouseLocation = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
      return screen
    }
    return window?.screen ?? NSScreen.main ?? NSScreen.screens.first!
  }
}

@MainActor
private final class DebugCaptureWindowController {
  private var window: NSWindow?

  func show(
    projectStore: ProjectStore,
    alertCenter: AppAlertCenter,
    languageStore: AppLanguageStore,
    workflowNavigator: WorkflowNavigator,
    recordingCoordinator: RecordingCoordinator,
    recordingSelection: RecordingSelectionModel
  ) {
    let win = window ?? makeWindow(
      projectStore: projectStore,
      alertCenter: alertCenter,
      languageStore: languageStore,
      workflowNavigator: workflowNavigator,
      recordingCoordinator: recordingCoordinator,
      recordingSelection: recordingSelection
    )
    window = win
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
  }

  private func makeWindow(
    projectStore: ProjectStore,
    alertCenter: AppAlertCenter,
    languageStore: AppLanguageStore,
    workflowNavigator: WorkflowNavigator,
    recordingCoordinator: RecordingCoordinator,
    recordingSelection: RecordingSelectionModel
  ) -> NSWindow {
    let root = AppLocalizedRoot {
      ContentView()
        .frame(minWidth: 980, minHeight: 680)
        .environment(projectStore)
        .environment(alertCenter)
        .environment(workflowNavigator)
        .environment(recordingCoordinator)
        .environment(recordingSelection)
    }
    .environment(languageStore)
    let host = NSHostingController(rootView: root)
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    win.title = "ArcShot Debug Capture"
    win.isReleasedWhenClosed = false
    win.contentViewController = host
    win.center()
    return win
  }
}

// MARK: - Menu commands

struct ArcShotCommands: Commands {
  var languageStore: AppLanguageStore
  var navigator: WorkflowNavigator
  var projectStore: ProjectStore
  var recordingCoordinator: RecordingCoordinator
  @FocusedValue(\.editorTimelineCommandContext) private var editorTimelineCommands

  private func isLocked(_ tab: WorkflowSidebarTab) -> Bool {
    projectStore.current == nil && !tab.isAvailableWithoutOpenProject
  }

  var body: some Commands {
    CommandMenu(languageStore.localized("ワークフロー")) {
      ForEach(WorkflowSidebarTab.allCases) { tab in
        Button(languageStore.localized(tab.title)) {
          guard !isLocked(tab) else { return }
          navigator.sidebarTab = tab
        }
        .disabled(isLocked(tab))
        .keyboardShortcut(tab.menuKeyEquivalent, modifiers: [.command])
      }
    }

    CommandMenu(languageStore.localized("収録")) {
      Button(languageStore.localized("録画ランチャーを前面へ")) {
        recordingCoordinator.setFloatingLauncherVisible(true)
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])

      Button(languageStore.localized("ArcShotワークスペースを表示")) {
        MainWorkspaceWindow.showKeyedMainWindow()
      }
      .disabled(projectStore.current == nil)
      .keyboardShortcut("o", modifiers: [.command, .shift])

      Divider()

      Button(languageStore.localized("録画を停止")) {
        Task { await recordingCoordinator.stopRecording() }
      }
      .keyboardShortcut(".", modifiers: [.command])
      .disabled(!recordingCoordinator.canStopRecording)
    }

    CommandMenu(languageStore.localized("タイムライン")) {
      Button(languageStore.localized("再生／一時停止")) {
        editorTimelineCommands?.togglePlayback()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut(.space, modifiers: [])

      Button(languageStore.localized("選択を削除")) {
        editorTimelineCommands?.deleteSelection()
      }
      .disabled(editorTimelineCommands?.canDeleteSelection != true)
      .keyboardShortcut(.delete, modifiers: [])

      Divider()

      Button(languageStore.localized("ズームイン")) {
        editorTimelineCommands?.zoomIn()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut("+", modifiers: .command)

      Button(languageStore.localized("ズームアウト")) {
        editorTimelineCommands?.zoomOut()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut("-", modifiers: .command)

      Button(languageStore.localized("全体表示")) {
        editorTimelineCommands?.zoomToFit()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut("0", modifiers: .command)

      Button(languageStore.localized(editorTimelineCommands?.snapEnabled == true ? "スナップをオフ" : "スナップをオン")) {
        editorTimelineCommands?.toggleSnap()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut("s", modifiers: [.command, .shift])

      Divider()

      Button(languageStore.localized("In点を再生位置へ")) {
        editorTimelineCommands?.setInAtPlayhead()
      }
      .disabled(editorTimelineCommands?.canUseSingleClipTrim != true)
      .keyboardShortcut("[", modifiers: .option)

      Button(languageStore.localized("Out点を再生位置へ")) {
        editorTimelineCommands?.setOutAtPlayhead()
      }
      .disabled(editorTimelineCommands?.canUseSingleClipTrim != true)
      .keyboardShortcut("]", modifiers: .option)

      Divider()

      Button(languageStore.localized("前の項目を選択")) {
        editorTimelineCommands?.selectPrevious()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut(.leftArrow, modifiers: .shift)

      Button(languageStore.localized("次の項目を選択")) {
        editorTimelineCommands?.selectNext()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut(.rightArrow, modifiers: .shift)

      Button(languageStore.localized("選択を解除")) {
        editorTimelineCommands?.clearSelection()
      }
      .disabled(editorTimelineCommands == nil)
      .keyboardShortcut(.escape, modifiers: [])
    }

    CommandGroup(after: .help) {
      Button(languageStore.localized("編集のキーボードショートカット…")) {
        navigator.showingReviewShortcutsHelp = true
      }
      .keyboardShortcut("?", modifiers: [.command, .shift])
    }

    #if DEBUG
    CommandMenu("Debug") {
      Button(languageStore.localized("開発用キャプチャ画面を表示")) {
        ArcShotRuntime.shared.showDebugCaptureWindow()
      }
      .keyboardShortcut("d", modifiers: [.command])
    }
    #endif
  }
}

@MainActor
final class GlobalRecordingShortcutController {
  private enum Shortcut {
    static let stopRecordingKeyCode: UInt16 = UInt16(kVK_ANSI_Period)
  }

  private weak var coordinator: RecordingCoordinator?
  nonisolated(unsafe) private var localMonitor: Any?
  nonisolated(unsafe) private var globalMonitor: Any?

  func bind(to coordinator: RecordingCoordinator) {
    self.coordinator = coordinator
    installIfNeeded()
  }

  deinit {
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
    }
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
    }
  }

  private func installIfNeeded() {
    guard localMonitor == nil, globalMonitor == nil else { return }

    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      if self.matchesStopShortcut(event: event) {
        self.stopIfNeeded()
        return nil
      }
      return event
    }

    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.matchesStopShortcut(event: event) else { return }
      self.stopIfNeeded()
    }
  }

  private func matchesStopShortcut(event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control), !flags.contains(.shift) else {
      return false
    }
    return event.keyCode == Shortcut.stopRecordingKeyCode
  }

  private func stopIfNeeded() {
    guard let coordinator, coordinator.canStopRecording else { return }
    Task { await coordinator.stopRecording() }
  }
}

@MainActor
enum ScreenshotTour {
  static let launchFlag = "-screenshotTour"

  static func outputDirectory(from arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
    guard let index = arguments.firstIndex(of: launchFlag),
      arguments.indices.contains(index + 1)
    else { return nil }
    return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
  }

  static var isActive: Bool {
    ProcessInfo.processInfo.arguments.contains(launchFlag)
  }

  static func run(outputDirectory: URL) async {
    UserDefaults.standard.set(
      true,
      forKey: AppIdentifiers.UserDefaultsKeys.recordingPermissionIntroCompleted
    )

    let runtime = ArcShotRuntime.shared
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for _ in 0 ..< 24 {
      if !runtime.projectStore.projects.isEmpty { break }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }

    if let firstProject = runtime.projectStore.projects.first {
      runtime.projectStore.loadProject(id: firstProject.id)
    }

    runtime.showWorkspace()
    try? await Task.sleep(nanoseconds: 900_000_000)
    runtime.applyMarketingScreenshotFrame()
    try? await Task.sleep(nanoseconds: 400_000_000)

    var captures: [(WorkflowSidebarTab, String)] = [
      (.capture, "01-capture.png"),
      (.library, "02-library.png"),
    ]
    if runtime.projectStore.current != nil {
      captures.append(contentsOf: [
        (.edit, "03-editor.png"),
        (.export, "04-export.png"),
      ])
    }

    for (tab, filename) in captures {
      runtime.workflowNavigator.sidebarTab = tab
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      if let window = runtime.workspaceWindowForMarketingScreenshot() {
        prepareWindowForCapture(window)
        try? await writePNG(from: window, to: outputDirectory.appendingPathComponent(filename))
      }
    }

    runtime.recordingCoordinator.setFloatingLauncherVisible(true)
    try? await Task.sleep(nanoseconds: 700_000_000)
    if let launcher = runtime.recordingLauncherWindowForMarketingScreenshot() {
      prepareWindowForCapture(launcher)
      try? await writePNG(from: launcher, to: outputDirectory.appendingPathComponent("05-recording-launcher.png"))
    }
  }

  private static func prepareWindowForCapture(_ window: NSWindow) {
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    NSApp.updateWindows()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
  }

  private static func writePNG(from window: NSWindow, to url: URL) async throws {
    if let data = await windowScreenshotPNGData(window) {
      try data.write(to: url, options: .atomic)
      return
    }

    guard let contentView = window.contentView else {
      throw CocoaError(.fileNoSuchFile)
    }
    contentView.layoutSubtreeIfNeeded()
    let bounds = contentView.bounds
    guard let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    contentView.cacheDisplay(in: bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
  }

  /// Uses ScreenCaptureKit so NavigationSplitView sidebars and materials render correctly.
  private static func windowScreenshotPNGData(_ window: NSWindow) async -> Data? {
    let windowID = CGWindowID(window.windowNumber)
    guard windowID != 0 else { return nil }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      let bundleID = Bundle.main.bundleIdentifier
      let scWindow =
        content.windows.first(where: { $0.windowID == windowID })
        ?? content.windows
        .filter { $0.owningApplication?.bundleIdentifier == bundleID }
        .max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })

      guard let scWindow else {
        return nil
      }

      let filter = SCContentFilter(desktopIndependentWindow: scWindow)
      let config = SCStreamConfiguration()
      let scale = max(1, window.backingScaleFactor.rounded())
      config.width = Int(scWindow.frame.width * scale)
      config.height = Int(scWindow.frame.height * scale)
      config.showsCursor = false

      let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      let bitmap = NSBitmapImageRep(cgImage: cgImage)
      return bitmap.representation(using: .png, properties: [:])
    } catch {
      return nil
    }
  }
}

@MainActor
final class ArcShotApplicationDelegate: NSObject, NSApplicationDelegate {
  private let dockMenu = NSMenu()
  private let stopItem = NSMenuItem(title: "録画を停止", action: #selector(stopRecording), keyEquivalent: "")
  private let discardItem = NSMenuItem(title: "録画を破棄", action: #selector(discardRecording), keyEquivalent: "")

  func applicationDidFinishLaunching(_ notification: Notification) {
    ArcShotRuntime.shared.start()
    RecordingCoordinator.prewarmCameraHardwareIfNeeded()
    if stopItem.target == nil {
      stopItem.target = self
      discardItem.target = self
      dockMenu.addItem(stopItem)
      dockMenu.addItem(discardItem)
    }
    refreshDockMenu()

    if let outputDirectory = ScreenshotTour.outputDirectory() {
      Task {
        await ScreenshotTour.run(outputDirectory: outputDirectory)
        NSApp.terminate(nil)
      }
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    ArcShotRuntime.shared.recordingCoordinator.refreshMediaPermissionState()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    ArcShotRuntime.shared.handleUserReopen()
    return true
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    refreshDockMenu()
    return dockMenu
  }

  private func refreshDockMenu() {
    let languageStore = ArcShotRuntime.shared.languageStore
    let canStop = ArcShotRuntime.shared.recordingCoordinator.canStopRecording
    stopItem.title = languageStore.localized("録画を停止")
    discardItem.title = languageStore.localized("録画を破棄")
    stopItem.isEnabled = canStop
    discardItem.isEnabled = canStop
  }

  @objc private func stopRecording() {
    Task { await ArcShotRuntime.shared.recordingCoordinator.stopRecording() }
  }

  @objc private func discardRecording() {
    Task { await ArcShotRuntime.shared.recordingCoordinator.discardRecording() }
  }
}

// MARK: - Help panel

struct ReviewShortcutsHelpSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
      Text("編集ショートカット")
        .font(.title2.weight(.semibold))

      Group {
        shortcutRow("Space", "再生／一時停止")
        shortcutRow("⌘Z", "取り消し")
        shortcutRow("⇧⌘Z", "やり直し")
        shortcutRow("← / →", "再生ヘッドを ±0.05 秒ずつ移動")
        shortcutRow("[ / ]", "前後のフレームへ（推定フレーム刻み）")
      }
      .font(.body)

      Text("編集トラック上でジェスチャーした後は ⌘Z でまとめて元に戻せます。")
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("閉じる") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(AppUIMetrics.rootPadding)
    .frame(minWidth: 440)
  }

  private func shortcutRow(_ keys: String, _ explanation: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(keys)
        .font(.body)
        .fontDesign(.monospaced)
        .frame(width: 120, alignment: .leading)
      Text(explanation)
    }
  }
}
