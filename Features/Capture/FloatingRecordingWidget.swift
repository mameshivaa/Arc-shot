import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Floating recording launcher (primary user capture UX)
//
// INVARIANT (docs/INVARIANTS.md §3):
//   Product recording: REC → CountdownOverlay (RecordingCountdown.seconds) → dismiss panel →
//   Task.yield() → RecordingCoordinator.startRecording. Dev RecordView is not this path.
//
// Do not call startRecording synchronously inside countdown number updates without yielding;
// it blocks SwiftUI body evaluation and looks like a freeze at "1".

extension SCContentFilter: @retroactive @unchecked Sendable {}

@MainActor
final class FloatingRecordingLauncherController {
  private enum Layout {
    static let distanceFromDock: CGFloat = 72
    static let recordingTopInset: CGFloat = 18
    static let recordingTrailingInset: CGFloat = 24

    @MainActor
    static func barWidth(coordinator: RecordingCoordinator?) -> CGFloat {
      RecordingLauncherPanelLayout.totalWidth(coordinator: coordinator)
    }
  }

  private enum PreflightCopy {
    static let pickTarget = "Choose a window to record."
    static let micSysConflict = "Microphone and System Audio cannot be used at the same time."
    static let screenRecording =
      "Screen Recording permission is required. Enable ArcShot under System Settings → Privacy & Security → Screen Recording."
    static let noWindows = "No shareable windows. Allow window access in Screen Recording settings."
  }

  private weak var coordinator: RecordingCoordinator?
  private weak var selectionModel: RecordingSelectionModel?
  private weak var projectStore: ProjectStore?
  private weak var workflowNavigator: WorkflowNavigator?
  private weak var alertCenter: AppAlertCenter?

  private var panel: NSPanel?
  private var barHostingController: NSHostingController<AnyView>?
  private var countdownPanel: NSPanel?
  private var countdownHostingController: NSHostingController<AnyView>?
  private var countdownTask: Task<Void, Never>?
  private var systemWindowPickerObserver: AnyObject?
  private var isSystemPickerPresented = false
  private var lastObservedState: RecordingState?
  private let cameraPreviewPanel = CameraRecordingPreviewPanel()
  private var cameraPresentationObserver: NSObjectProtocol?

  func forceDismissForEditor() {
    cancelCountdownIfNeeded()
    cameraPreviewPanel.dismiss()
    panel?.orderOut(nil)
    dismissSystemWindowPickerIfNeeded()
  }

  func marketingScreenshotWindow() -> NSWindow? {
    panel
  }

  func bind(
    coordinator: RecordingCoordinator,
    selectionModel: RecordingSelectionModel,
    projectStore: ProjectStore,
    workflowNavigator: WorkflowNavigator,
    alertCenter: AppAlertCenter
  ) {
    self.coordinator = coordinator
    self.selectionModel = selectionModel
    self.projectStore = projectStore
    self.workflowNavigator = workflowNavigator
    self.alertCenter = alertCenter

    if let cameraPresentationObserver {
      NotificationCenter.default.removeObserver(cameraPresentationObserver)
    }
    cameraPresentationObserver = NotificationCenter.default.addObserver(
      forName: AppIdentifiers.CaptureNotifications.cameraPresentationChanged,
      object: coordinator,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.updateCameraRecordingPreview()
      }
    }

    lastObservedState = coordinator.state
    startObservationLoop()
    updatePresentation()

  }

  private func startObservationLoop() {
    guard let coordinator, let selectionModel else { return }
    withObservationTracking {
      _ = coordinator.state
      _ = coordinator.isFloatingLauncherVisible
      _ = coordinator.isBusy
      _ = coordinator.lastErrorMessage
      _ = coordinator.isFinalizingStoppedRecording
      _ = coordinator.recordingElapsedSeconds
      _ = coordinator.isCameraEnabled
      _ = coordinator.isCameraPreviewStarting
      _ = coordinator.activeCameraCaptureSession?.isRunning
      _ = coordinator.isMicrophoneEnabled
      _ = coordinator.isSystemAudioEnabled
      _ = coordinator.isCursorCaptureEnabled
      _ = selectionModel.selectedSourceType
      _ = selectionModel.selectedSource
      _ = selectionModel.selectedSourceRecordingLabel
      _ = self.projectStore?.projects
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleObservedChange()
      }
    }
  }

  private func handleObservedChange() {
    guard let coordinator else { return }
    let newState = coordinator.state
    if newState == .finished, lastObservedState != .finished {
      coordinator.setFloatingLauncherVisible(false)
      forceDismissForEditor()
    }
    refreshRootView()
    updatePresentation()
    updateCameraRecordingPreview()
    if newState == .finished, lastObservedState != .finished {
      scheduleFinalizeAfterStopIfNeeded()
    }
    lastObservedState = newState
    startObservationLoop()
  }

  private func scheduleFinalizeAfterStopIfNeeded() {
    guard let coordinator,
      let selectionModel,
      let projectStore,
      let workflowNavigator,
      let alertCenter
    else { return }

    guard !coordinator.isSuppressingEditorFinalizeForDiscard else { return }

    Task { @MainActor in
      await RecordingSessionFinalization.finalizeAfterUserStoppedRecording(
        coordinator: coordinator,
        projectStore: projectStore,
        workflowNav: workflowNavigator,
        alertCenter: alertCenter,
        selectedSource: selectionModel.selectedSource
      )
    }
  }

  private func updatePresentation() {
    guard let coordinator else { return }
    guard coordinator.isFloatingLauncherVisible else {
      panel?.orderOut(nil)
      cameraPreviewPanel.dismiss()
      dismissSystemWindowPickerIfNeeded()
      return
    }

    guard !isSystemPickerPresented else {
      panel?.orderOut(nil)
      return
    }

    rebuildPanelRootIfInstalled()
    repositionPanel()
    panel?.orderFrontRegardless()
  }

  private func refreshRootView() {
    rebuildPanelRootIfInstalled()
    repositionPanel()
    if coordinator?.isFloatingLauncherVisible == true, !isSystemPickerPresented {
      panel?.orderFrontRegardless()
    }
  }

  private func rebuildPanelRootIfInstalled() {
    guard let coordinator else { return }
    guard let selectionModel else { return }

    let width = Layout.barWidth(coordinator: coordinator)
    let height = RecordingLauncherPanelLayout.totalHeight(coordinator: coordinator)

    if panel == nil {
      let rect = CGRect(x: 0, y: 0, width: width, height: height)
      let panel = NSPanel(
        contentRect: rect,
        styleMask: [.nonactivatingPanel, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      panel.titleVisibility = .hidden
      panel.titlebarAppearsTransparent = true
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.isMovableByWindowBackground = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.contentView?.wantsLayer = true
      panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
      panel.hasShadow = false
      panel.standardWindowButton(.closeButton)?.isHidden = true
      panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
      panel.standardWindowButton(.zoomButton)?.isHidden = true
      self.panel = panel
    }

    guard let panel else { return }

    let actions = makeBarActions(
      coordinator: coordinator,
      selectionModel: selectionModel
    )
    let root = AnyView(
      AppLocalizedRoot {
        RecordingLauncherBarLive(
          coordinator: coordinator,
          selectionModel: selectionModel,
          recentProjects: Array((self.projectStore?.projects ?? []).prefix(5)),
          actions: actions
        )
      }
      .environment(ArcShotRuntime.shared.languageStore)
    )

    if let barHostingController {
      barHostingController.rootView = root
      barHostingController.view.frame = NSRect(origin: .zero, size: CGSize(width: width, height: height))
      configureTransparentHostingView(barHostingController.view)
    } else {
      let host = NSHostingController(rootView: root)
      host.view.frame = NSRect(origin: .zero, size: CGSize(width: width, height: height))
      configureTransparentHostingView(host.view)
      panel.contentViewController = host
      barHostingController = host
    }
  }

  private func configureTransparentHostingView(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.layer?.masksToBounds = false
  }

  private func makeBarActions(coordinator: RecordingCoordinator, selectionModel: RecordingSelectionModel)
    -> RecordingLauncherBarActions
  {
    RecordingLauncherBarActions(
      quitApplication: { [weak self] in
        self?.dismissSystemWindowPickerIfNeeded()
        NSApp.terminate(nil)
      },
      openWorkspace: { [weak self] in
        self?.dismissSystemWindowPickerIfNeeded()
        guard self?.projectStore?.current != nil else {
          coordinator.reportLauncherPreflightIssue("The editor opens after you stop a recording.")
          return
        }
        NSApp.activate(ignoringOtherApps: true)
        MainWorkspaceWindow.showKeyedMainWindow()
      },
      openProjectLibrary: { [weak self] in
        guard let self, let workflowNavigator = self.workflowNavigator else { return }
        self.dismissSystemWindowPickerIfNeeded()
        workflowNavigator.sidebarTab = .library
        coordinator.setFloatingLauncherVisible(false)
        NSApp.activate(ignoringOtherApps: true)
        MainWorkspaceWindow.showKeyedMainWindow()
      },
      openProject: { [weak self] projectID in
        guard let self,
          let projectStore = self.projectStore,
          let workflowNavigator = self.workflowNavigator
        else { return }
        self.dismissSystemWindowPickerIfNeeded()
        projectStore.loadProject(id: projectID)
        guard projectStore.current?.id == projectID else {
          coordinator.reportLauncherPreflightIssue("Could not open that recording.")
          return
        }
        workflowNavigator.sidebarTab = .edit
        coordinator.setFloatingLauncherVisible(false)
        NSApp.activate(ignoringOtherApps: true)
        MainWorkspaceWindow.showKeyedMainWindow()
      },
      revealProjectInFinder: { [weak self] projectID in
        self?.projectStore?.revealProjectInFinder(id: projectID)
      },
      deleteProject: { [weak self] projectID in
        self?.projectStore?.deleteProject(id: projectID)
      },
      record: { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          self.dismissSystemWindowPickerIfNeeded()
          guard selectionModel.selectedSource != nil else {
            await self.pickWindow(selectionModel: selectionModel)
            return
          }
          guard await self.validateBeforeRecording(selectionModel: selectionModel, coordinator: coordinator) else { return }
          self.startCountdownThenRecord(coordinator: coordinator, selectionModel: selectionModel)
        }
      },
      stopRecording: { await coordinator.stopRecording() },
      discardRecording: { await coordinator.discardRecording() },
      openEditorNow: {
        coordinator.setFloatingLauncherVisible(false)
        NSApp.activate(ignoringOtherApps: true)
        MainWorkspaceWindow.presentKey()
      },
      dismissRibbonError: {
        coordinator.clearLastErrorForLauncher()
      },
      pickWindow: { [weak self] in
        guard let self else { return }
        await self.pickWindow(selectionModel: selectionModel)
      }
    )
  }

  private func dismissSystemWindowPickerIfNeeded() {
    SCContentSharingPicker.shared.isActive = false
    if let observer = systemWindowPickerObserver as? SystemWindowPickerObserver {
      SCContentSharingPicker.shared.remove(observer)
    }
    systemWindowPickerObserver = nil
    isSystemPickerPresented = false
  }

  private func finishSystemWindowPicker() {
    dismissSystemWindowPickerIfNeeded()
    updatePresentation()
  }

  private func repositionPanel() {
    guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let vf = screen.visibleFrame
    let width = Layout.barWidth(coordinator: coordinator)
    let height = RecordingLauncherPanelLayout.totalHeight(coordinator: coordinator)
    let origin = panelOrigin(
      for: coordinator?.state,
      in: vf,
      width: width,
      height: height
    )
    panel.setFrame(
      CGRect(
        x: origin.x,
        y: origin.y,
        width: width,
        height: height
      ),
      display: true
    )
  }

  private func panelOrigin(
    for state: RecordingState?,
    in visibleFrame: CGRect,
    width: CGFloat,
    height: CGFloat
  ) -> CGPoint {
    switch state {
    case .armed, .recording:
      return CGPoint(
        x: max(visibleFrame.minX, visibleFrame.maxX - width - Layout.recordingTrailingInset),
        y: max(visibleFrame.minY, visibleFrame.maxY - height - Layout.recordingTopInset)
      )
    case .idle, .failed, .finished, nil:
      return CGPoint(
        x: visibleFrame.midX - width / 2,
        y: visibleFrame.minY + Layout.distanceFromDock
      )
    }
  }

  private func pickWindow(selectionModel: RecordingSelectionModel) async {
    guard let coordinator else { return }
    guard !coordinator.isBusy && !isRecordingBusy(coordinator) else { return }

    presentSystemPicker(selectionModel: selectionModel, coordinator: coordinator)
  }

  private func presentSystemPicker(
    selectionModel: RecordingSelectionModel,
    coordinator: RecordingCoordinator
  ) {
    let sourceType = selectionModel.selectedSourceType
    dismissSystemWindowPickerIfNeeded()
    panel?.orderOut(nil)
    isSystemPickerPresented = true

    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = sourceType == .desktop ? .singleDisplay : .singleWindow
    configuration.allowsChangingSelectedContent = false
    if let bundleID = Bundle.main.bundleIdentifier {
      configuration.excludedBundleIDs = [bundleID]
    }

    let observer = SystemWindowPickerObserver(
      onUpdate: { [weak self, weak selectionModel] filter in
        guard let selectionModel else { return }
        let selection = self?.makeSystemPickerSelection(
          filter: filter,
          sourceType: sourceType
        ) ?? Self.defaultSystemPickerSelection(filter: filter, sourceType: sourceType)
        selectionModel.applySystemPickerSelection(selection)
        self?.finishSystemWindowPicker()
      },
      onCancel: { [weak self] in
        self?.finishSystemWindowPicker()
      },
      onFailure: { [weak self, weak coordinator] error in
        coordinator?.reportLauncherPreflightIssue(error.localizedDescription)
        self?.finishSystemWindowPicker()
      }
    )

    let picker = SCContentSharingPicker.shared
    systemWindowPickerObserver = observer
    picker.defaultConfiguration = configuration
    picker.add(observer)
    picker.isActive = true
    picker.present(using: sourceType == .desktop ? .display : .window)
  }

  private func makeSystemPickerSelection(
    filter: SCContentFilter,
    sourceType: RecordingSelectionModel.TargetMode
  ) -> CaptureSource.SystemPickerSelection {
    let rect = filter.contentRect
    let style = Self.contentStyle(for: sourceType)
    let displayName = Self.systemPickerDisplayName(
      filter: filter,
      sourceType: sourceType
    )
    return CaptureSource.SystemPickerSelection(
      id: "system-\(sourceType.rawValue)-\(UUID().uuidString)",
      style: style,
      filter: filter,
      displayName: displayName,
      contentRect: rect,
      pointPixelScale: filter.pointPixelScale
    )
  }

  private static func defaultSystemPickerSelection(
    filter: SCContentFilter,
    sourceType: RecordingSelectionModel.TargetMode
  ) -> CaptureSource.SystemPickerSelection {
    CaptureSource.SystemPickerSelection(
      id: "system-\(sourceType.rawValue)-\(UUID().uuidString)",
      style: contentStyle(for: sourceType),
      filter: filter,
      displayName: sourceType == .desktop ? "Desktop" : "Selected window",
      contentRect: filter.contentRect,
      pointPixelScale: filter.pointPixelScale
    )
  }

  private static func contentStyle(for sourceType: RecordingSelectionModel.TargetMode) -> SCShareableContentStyle {
    sourceType == .desktop ? .display : .window
  }

  private static func systemPickerDisplayName(
    filter: SCContentFilter,
    sourceType: RecordingSelectionModel.TargetMode
  ) -> String {
    if sourceType == .desktop {
      if let display = filter.includedDisplays.first {
        return "Desktop \(display.displayID)"
      }
      return "Desktop"
    }

    if let pickedWindow = filter.includedWindows.first {
      return windowDisplayName(pickedWindow)
    }

    return filter.includedWindows.first.map(windowDisplayName) ?? "Selected window"
  }

  private func startCountdownThenRecord(
    coordinator: RecordingCoordinator,
    selectionModel: RecordingSelectionModel
  ) {
    guard let source = selectionModel.selectedSource else {
      coordinator.reportLauncherPreflightIssue(PreflightCopy.pickTarget)
      return
    }
    guard shouldRequireScreenRecordingPreflight(for: source) == false || ScreenCaptureAccess.missingCriticalPermissions().isEmpty else {
      coordinator.reportLauncherPreflightIssue(PreflightCopy.screenRecording)
      return
    }
    coordinator.clearLastErrorForLauncher()
    MainWorkspaceWindow.orderOutKeyedMainWindow()

    countdownTask?.cancel()
    presentCountdownPanel(secondsRemaining: RecordingCountdown.seconds)
    countdownTask = Task { @MainActor [weak self] in
      for remaining in stride(from: RecordingCountdown.seconds, through: 1, by: -1) {
        self?.updateCountdownPanel(secondsRemaining: remaining)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if Task.isCancelled {
          self?.dismissCountdownPanel()
          return
        }
      }
      self?.dismissCountdownPanel()
      // Yield so countdown panel orderOut completes before heavy startRecording work on MainActor.
      await Task.yield()
      await coordinator.startRecording(source: source)
    }
  }

  private func cancelCountdownIfNeeded() {
    countdownTask?.cancel()
    countdownTask = nil
    dismissCountdownPanel()
  }

  private func presentCountdownPanel(secondsRemaining: Int) {
    let screen = targetCountdownScreen()
    let frame = screen.frame

    if countdownPanel == nil {
      let panel = NSPanel(
        contentRect: frame,
        styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
        backing: .buffered,
        defer: false
      )
      panel.titleVisibility = .hidden
      panel.titlebarAppearsTransparent = true
      panel.isFloatingPanel = true
      panel.level = .screenSaver
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      panel.isMovable = false
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      countdownPanel = panel
    }

    guard let countdownPanel else { return }
    updateCountdownPanel(secondsRemaining: secondsRemaining)
    countdownPanel.setFrame(frame, display: true)
    countdownPanel.orderFrontRegardless()
  }

  private func updateCountdownPanel(secondsRemaining: Int) {
    guard let countdownPanel else { return }

    let root = AnyView(
      AppLocalizedRoot {
        CountdownOverlay(secondsRemaining: secondsRemaining)
      }
      .environment(ArcShotRuntime.shared.languageStore)
    )

    if let countdownHostingController {
      countdownHostingController.rootView = root
      countdownHostingController.view.frame = countdownPanel.contentView?.bounds ?? .zero
    } else {
      let host = NSHostingController(rootView: root)
      host.view.frame = countdownPanel.contentView?.bounds ?? .zero
      configureTransparentHostingView(host.view)
      countdownPanel.contentViewController = host
      countdownHostingController = host
    }
  }

  private func dismissCountdownPanel() {
    countdownPanel?.orderOut(nil)
  }

  private func targetCountdownScreen() -> NSScreen {
    let mouseLocation = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
      return screen
    }
    return panel?.screen ?? NSScreen.main ?? NSScreen.screens.first!
  }

  private func shouldRequireScreenRecordingPreflight(for source: CaptureSource) -> Bool {
    switch source {
    case .systemPickerSelection:
      return false
    }
  }

  private func validateBeforeRecording(selectionModel: RecordingSelectionModel, coordinator: RecordingCoordinator) async -> Bool {
    guard selectionModel.selectedSource != nil else {
      coordinator.reportLauncherPreflightIssue(PreflightCopy.pickTarget)
      return false
    }
    return true
  }

  private func updateCameraRecordingPreview() {
    guard let coordinator else {
      cameraPreviewPanel.dismiss()
      return
    }
    let session = coordinator.activeCameraCaptureSession
    let shouldShow =
      coordinator.isFloatingLauncherVisible
      && coordinator.isCameraEnabled
      && !coordinator.isFinalizingStoppedRecording
      && (coordinator.isCameraPreviewStarting || session != nil)
    let isLoading = shouldShow && session == nil && coordinator.isCameraPreviewStarting
    cameraPreviewPanel.update(session: session, isVisible: shouldShow, isLoading: isLoading)
    if shouldShow {
    } else {
      cameraPreviewPanel.dismiss()
    }
  }
}

private extension FloatingRecordingLauncherController {
  private func isRecordingBusy(_ coordinator: RecordingCoordinator) -> Bool {
    coordinator.state == .armed || coordinator.state == .recording
  }
}

private final class SystemWindowPickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
  private let onUpdate: @MainActor (SCContentFilter) -> Void
  private let onCancel: @MainActor () -> Void
  private let onFailure: @MainActor (Error) -> Void

  init(
    onUpdate: @escaping @MainActor (SCContentFilter) -> Void,
    onCancel: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (Error) -> Void
  ) {
    self.onUpdate = onUpdate
    self.onCancel = onCancel
    self.onFailure = onFailure
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
    Task { @MainActor in
      onUpdate(filter)
    }
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    Task { @MainActor in
      onCancel()
    }
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    Task { @MainActor in
      onFailure(error)
    }
  }
}

private func windowDisplayName(_ window: SCWindow) -> String {
  let app = windowAppName(window)
  let title = windowTitle(window)
  if title == "Untitled" || title == app { return app }
  return "\(app) — \(title)"
}

private func windowAppName(_ window: SCWindow) -> String {
  let app = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return app.isEmpty ? "Window" : app
}

private func windowTitle(_ window: SCWindow) -> String {
  let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return title.isEmpty ? "Untitled" : title
}
