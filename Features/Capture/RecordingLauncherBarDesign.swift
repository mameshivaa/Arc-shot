import AppKit
import SwiftUI

// MARK: - Design tokens（録画バー専用）

enum RecordingLauncherBarMetrics {
  /// 受け入れ 64px 以内のうえで余白を詰める
  static let barHeight: CGFloat = 64
  /// 実コンテンツ幅に合わせた固定幅（`Spacer` による中央の dead space を防ぐ）
  static let barWidth: CGFloat = RecordingLauncherIdleLayout.idleChromeWidth
  static let recordingBarHeight: CGFloat = 42
  static let recordingBarWidth: CGFloat = 240
  static let visualBleedInset: CGFloat = 16
  static let cornerRadius: CGFloat = 20
  static let horizontalPadding: CGFloat = 18
  static let interGroupSpacing: CGFloat = 10
  static let spacingMicDeniedRibbonToBar: CGFloat = 5
  /// メッセージ1行のみのときの帯のおおよその高さ（パネルの `setFrame` 用）。
  static let permissionRibbonApproximateHeight: CGFloat = 28
}

// MARK: - Copy keys（`AppLanguageStore` 経由で表示）

private enum RecordingLauncherCopyKey {
  static let openSettings = "Open Settings"
  static let dismiss = "Dismiss"
  static let screenRecordingRequired =
    "Screen Recording permission is required. Enable ArcShot under System Settings → Privacy & Security → Screen Recording."
  static let openingEditorPrimary = "Opening editor…"
  static let openingEditorSecondary = "Your recording will appear automatically."
  static let openNow = "Open now"
  static let recordTileLabel = "Record"
  static let selectTargetTileLabel = "Select Target"
  static let recentRecordingsTileLabel = "Recent"
  static let recentRecordingsAccessibility = "Recent Recordings"
  static let recentRecordingsHelp = "Edit Recent Recording"
  static let noRecordingsYet = "No recordings yet"
  static let openRecentRecording = "Open"
  static let revealInFinder = "Show in Finder"
  static let deleteRecording = "Delete"
  static let openProjectLibrary = "Open Library"
  static let deleteRecordingConfirmationTitle = "Delete this recording?"
}

private struct LauncherLabeledTile: View {
  let systemImage: String
  let title: String
  let foreground: Color
  var width: CGFloat = RecordingLauncherIdleLayout.actionTileWidth
  var isActive: Bool = false
  var isWarning: Bool = false
  var isDisabled: Bool = false
  var tint: Color? = nil

  var body: some View {
    VStack(spacing: RecordingLauncherIdleLayout.tileContentSpacing) {
      Image(systemName: systemImage)
        .font(.system(size: RecordingLauncherIdleLayout.inputGlyphSize, weight: .medium))
      Text(title)
        .font(.system(size: RecordingLauncherIdleLayout.inputLabelSize, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .foregroundStyle(isWarning ? LauncherLiquidGlassColor.warning : foreground)
    .padding(.horizontal, RecordingLauncherIdleLayout.tileHorizontalInset)
    .frame(width: width, height: RecordingLauncherIdleLayout.tileHeight)
    .launcherTileChrome(
      isActive: isActive,
      isWarning: isWarning,
      isDisabled: isDisabled,
      tint: tint
    )
  }
}

private struct LauncherIconTile: View {
  let systemImage: String
  let foreground: Color
  var isDisabled: Bool = false

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: RecordingLauncherIdleLayout.auxiliaryIconSize, weight: .semibold))
      .foregroundStyle(foreground)
      .frame(
        width: RecordingLauncherIdleLayout.utilityButtonSize,
        height: RecordingLauncherIdleLayout.tileHeight
      )
      .launcherTileChrome(isActive: false, isWarning: false, isDisabled: isDisabled)
  }
}

private struct LauncherRecordTile: View {
  let systemImage: String
  let title: String
  let isEnabled: Bool
  let isReady: Bool
  var tint: Color? = nil

  var body: some View {
    VStack(spacing: RecordingLauncherIdleLayout.tileContentSpacing) {
      Image(systemName: systemImage)
        .font(.system(size: RecordingLauncherIdleLayout.recordGlyphSize, weight: .semibold))
      Text(title)
        .font(.system(size: RecordingLauncherIdleLayout.recordLabelSize, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .foregroundStyle(recordForeground)
    .padding(.horizontal, RecordingLauncherIdleLayout.tileHorizontalInset)
    .frame(
      width: RecordingLauncherIdleLayout.recordTileWidth,
      height: RecordingLauncherIdleLayout.tileHeight
    )
    .launcherTileChrome(
      isActive: isReady,
      isWarning: false,
      isDisabled: !isEnabled,
      isAwaitingTarget: isEnabled && !isReady,
      tint: tint
    )
  }

  private var recordForeground: Color {
    guard isEnabled else { return .secondary }
    if isReady { return LauncherLiquidGlassColor.record }
    return .secondary
  }
}

private struct RecordingLauncherCompactRibbon: View {
  let message: String
  var primaryTitle: String?
  var onPrimary: () -> Void
  var dismissTitle: String?
  var onDismiss: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(LauncherLiquidGlassColor.warning)
        .accessibilityHidden(true)

      Text(message)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .minimumScaleFactor(0.82)

      Spacer(minLength: 0)

      if let dismissTitle, let onDismiss {
        Button(action: onDismiss) {
          Text(dismissTitle)
        }
        .launcherSystemGlassButton()
      }

      if let primaryTitle {
        Button(action: onPrimary) {
          Text(primaryTitle)
        }
        .launcherSystemGlassButton(tint: LauncherLiquidGlassColor.warning, prominent: true)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(width: RecordingLauncherBarMetrics.barWidth, alignment: .leading)
    .launcherGlassBackground(
      tint: LauncherLiquidGlassColor.warning.opacity(0.18),
      cornerRadius: RecordingLauncherMicRibbonStyle.corner
    )
    .overlay(
      RoundedRectangle(cornerRadius: RecordingLauncherMicRibbonStyle.corner, style: .continuous)
        .stroke(LauncherLiquidGlassColor.warning.opacity(0.35), lineWidth: 0.8)
    )
    .accessibilityElement(children: .combine)
  }
}

private enum LauncherLiquidGlassColor {
  static let selection = Color.accentColor
  static let record = Color(red: 0.94, green: 0.12, blue: 0.16)
  static let warning = Color(red: 0.90, green: 0.42, blue: 0.00)
}

private enum RecordingLauncherIdleLayout {
  static let mainSpacing: CGFloat = 10
  static let targetTileWidth: CGFloat = 104
  static let inputTileWidth: CGFloat = 62
  static let recordingStatusTileWidth: CGFloat = 96
  static let tileHeight: CGFloat = 48
  static let tileContentSpacing: CGFloat = 5
  static let tileHorizontalInset: CGFloat = 4
  static let targetGlyphSize: CGFloat = 17
  static let inputGlyphSize: CGFloat = 15
  static let targetLabelSize: CGFloat = 10
  static let targetCaptionSize: CGFloat = 8.5
  static let inputLabelSize: CGFloat = 9
  static let inputGroupSpacing: CGFloat = 7
  static let dividerHeight: CGFloat = 40
  static let utilityButtonSize: CGFloat = 44
  static let auxiliaryIconSize: CGFloat = 12
  static let actionTileWidth: CGFloat = 62
  static let recordTileWidth: CGFloat = 100
  static let recordGlyphSize: CGFloat = 18
  static let recordLabelSize: CGFloat = 10
  static let auxiliaryGroupSpacing: CGFloat = 8
  static let utilityClusterSpacing: CGFloat = 7
  static let tileCornerRadius: CGFloat = 11
  static let minFlexibleGap: CGFloat = 20

  static var idleChromeWidth: CGFloat {
    let targetCluster = targetTileWidth * 2 + mainSpacing
    let inputCluster = inputTileWidth * 4 + inputGroupSpacing * 3
    let utilityCluster = actionTileWidth + utilityButtonSize * 2 + utilityClusterSpacing * 2
    let auxiliaryCluster = recordTileWidth + auxiliaryGroupSpacing + utilityCluster
    let groupGaps = mainSpacing * 4 + 2
    return targetCluster + inputCluster + auxiliaryCluster + groupGaps
      + RecordingLauncherBarMetrics.horizontalPadding * 2
      + minFlexibleGap
  }
}

private enum RecordingLauncherMicRibbonStyle {
  static let corner: CGFloat = 10
}

private enum RecordingLauncherManualOpenStyle {
  static let horizontalPadding: CGFloat = 6
  static let verticalPadding: CGFloat = 3
}

// MARK: - Live bar（フローティングランチャー）

private struct RecordingLauncherTopRibbonDescriptor: Equatable {
  var message: String
  var settingsPermission: ScreenCaptureAccess.Permission?
  var showDismiss: Bool
}

private enum RecordingLauncherTopRibbonResolver {
  @MainActor
  static func resolve(
    coordinator: RecordingCoordinator,
    selectionModel: RecordingSelectionModel? = nil
  ) -> RecordingLauncherTopRibbonDescriptor? {
    if coordinator.state == .finished {
      return nil
    }

    let recordingLike = coordinator.state == .recording || coordinator.state == .armed

    if let msg = coordinator.lastErrorMessage, !msg.isEmpty {
      return RecordingLauncherTopRibbonDescriptor(
        message: msg,
        settingsPermission: settingsPermission(for: msg),
        showDismiss: true
      )
    }

    if recordingLike { return nil }

    let screenRecordingState = ScreenCaptureAccess.permissionStatuses()
      .first { $0.permission == .screenRecording }?.state ?? .denied
    if screenRecordingState != .granted && requiresScreenRecordingPreflight(selectionModel: selectionModel) {
      return RecordingLauncherTopRibbonDescriptor(
        message: ArcShotRuntime.shared.languageStore.localized(RecordingLauncherCopyKey.screenRecordingRequired),
        settingsPermission: .screenRecording,
        showDismiss: false
      )
    }

    return nil
  }

  @MainActor
  private static func requiresScreenRecordingPreflight(selectionModel: RecordingSelectionModel?) -> Bool {
    guard let source = selectionModel?.selectedSource else { return true }
    switch source {
    case .systemPickerSelection:
      return false
    }
  }

  private static func settingsPermission(for message: String) -> ScreenCaptureAccess.Permission? {
    if message.contains("macOS 14") { return nil }
    if message.contains("録画ストリーム") { return nil }
    if message.contains("マイク") { return .microphone }
    if message.contains("カメラ") { return .camera }
    return .screenRecording
  }
}

enum RecordingLauncherPanelLayout {
  static var totalWidth: CGFloat {
    RecordingLauncherBarMetrics.barWidth + RecordingLauncherBarMetrics.visualBleedInset * 2
  }

  @MainActor
  static func totalWidth(coordinator: RecordingCoordinator?) -> CGFloat {
    contentWidth(coordinator: coordinator)
      + RecordingLauncherBarMetrics.visualBleedInset * 2
  }

  @MainActor
  static func totalHeight(coordinator: RecordingCoordinator?, selectionModel: RecordingSelectionModel? = nil) -> CGFloat {
    contentHeight(coordinator: coordinator, selectionModel: selectionModel)
      + RecordingLauncherBarMetrics.visualBleedInset * 2
  }

  @MainActor
  static func contentWidth(coordinator: RecordingCoordinator?) -> CGFloat {
    guard let coordinator else { return RecordingLauncherBarMetrics.barWidth }
    switch coordinator.state {
    case .recording, .armed:
      return RecordingLauncherBarMetrics.recordingBarWidth
    case .idle, .failed, .finished:
      return RecordingLauncherBarMetrics.barWidth
    }
  }

  @MainActor
  static func contentHeight(coordinator: RecordingCoordinator?, selectionModel: RecordingSelectionModel? = nil) -> CGFloat {
    chromeHeight(coordinator: coordinator)
      + ribbonExtraHeight(coordinator: coordinator, selectionModel: selectionModel)
  }

  @MainActor
  static func chromeHeight(coordinator: RecordingCoordinator?) -> CGFloat {
    guard let coordinator else {
      return RecordingLauncherBarMetrics.barHeight
    }
    return switch coordinator.state {
    case .recording, .armed:
      RecordingLauncherBarMetrics.recordingBarHeight
    case .idle, .failed, .finished:
      RecordingLauncherBarMetrics.barHeight
    }
  }

  @MainActor
  private static func ribbonExtraHeight(
    coordinator: RecordingCoordinator?,
    selectionModel: RecordingSelectionModel?
  ) -> CGFloat {
    guard let coordinator else { return 0 }
    let ribbonShown = RecordingLauncherTopRibbonResolver.resolve(
      coordinator: coordinator,
      selectionModel: selectionModel
    ) != nil
    return ribbonShown
      ? RecordingLauncherBarMetrics.permissionRibbonApproximateHeight
        + RecordingLauncherBarMetrics.spacingMicDeniedRibbonToBar
      : 0
  }
}

struct RecordingLauncherBarActions {
  var quitApplication: () -> Void
  var openWorkspace: () -> Void
  var openProjectLibrary: () -> Void
  var openProject: (UUID) -> Void
  var revealProjectInFinder: (UUID) -> Void
  var deleteProject: (UUID) -> Void
  var record: () -> Void
  var stopRecording: () async -> Void
  var discardRecording: () async -> Void
  var openEditorNow: () -> Void
  var dismissRibbonError: () -> Void
  var pickWindow: () async -> Void
}

private enum RecordingLauncherElapsedFormatter {
  static func mmss(from seconds: Double) -> String {
    let s = Int(seconds.rounded(.towardZero))
    let m = s / 60
    let r = s % 60
    return String(format: "%02d:%02d", m, r)
  }
}

struct RecordingLauncherBarLive: View {
  var coordinator: RecordingCoordinator
  var selectionModel: RecordingSelectionModel
  var recentProjects: [ProjectStore.ProjectSummary]
  let actions: RecordingLauncherBarActions
  @Environment(AppLanguageStore.self) private var languageStore
  // 誤クリックで即終了しないよう、終了は確認後に実行する。
  @State private var isQuitConfirmationPresented = false
  @State private var isRecordingPulseActive = false
  @State private var projectPendingDeleteID: UUID?

  var body: some View {
    let ribbon = RecordingLauncherTopRibbonResolver.resolve(coordinator: coordinator, selectionModel: selectionModel)
    let contentWidth = RecordingLauncherPanelLayout.contentWidth(coordinator: coordinator)
    let chromeHeight = RecordingLauncherPanelLayout.chromeHeight(coordinator: coordinator)
    VStack(alignment: .leading, spacing: ribbon == nil ? 0 : RecordingLauncherBarMetrics.spacingMicDeniedRibbonToBar) {
      if let ribbon {
        RecordingLauncherCompactRibbon(
          message: ribbon.message,
          primaryTitle: ribbon.settingsPermission.map { _ in text(RecordingLauncherCopyKey.openSettings) },
          onPrimary: {
            if let p = ribbon.settingsPermission {
              ScreenCaptureAccess.openSettings(for: p)
            }
          },
          dismissTitle: ribbon.showDismiss ? text(RecordingLauncherCopyKey.dismiss) : nil,
          onDismiss: ribbon.showDismiss ? actions.dismissRibbonError : nil
        )
      }

      Group {
        switch coordinator.state {
        case .recording, .armed:
          recordingChromeLive
        case .finished:
          postStopChromeLive
        case .idle, .failed:
          idleChromeLive
        }
      }
      .frame(width: contentWidth, height: chromeHeight)
      .launcherUnifiedGlassSurface()
      .allowsHitTesting(true)
      .opacity(idleBusyDimOpacity)
    }
    .frame(width: contentWidth, alignment: .leading)
    .padding(RecordingLauncherBarMetrics.visualBleedInset)
    .frame(
      width: RecordingLauncherPanelLayout.totalWidth(coordinator: coordinator),
      height: RecordingLauncherPanelLayout.totalHeight(coordinator: coordinator, selectionModel: selectionModel),
      alignment: .center
    )
    .alert(text("ArcShotを終了しますか？"), isPresented: $isQuitConfirmationPresented) {
      Button(text("終了"), role: .destructive) {
        actions.quitApplication()
      }
      Button(text("キャンセル"), role: .cancel) {}
    } message: {
      Text("録画ランチャーとワークスペースを閉じてArcShotを終了します。")
    }
    .confirmationDialog(
      text(RecordingLauncherCopyKey.deleteRecordingConfirmationTitle),
      isPresented: Binding(
        get: { projectPendingDeleteID != nil },
        set: { if !$0 { projectPendingDeleteID = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(text(RecordingLauncherCopyKey.deleteRecording), role: .destructive) {
        guard let id = projectPendingDeleteID else { return }
        actions.deleteProject(id)
        projectPendingDeleteID = nil
      }
      Button(text("キャンセル"), role: .cancel) {
        projectPendingDeleteID = nil
      }
    }
  }

  private var idleBusyDimOpacity: Double {
    if coordinator.state == .recording || coordinator.state == .armed { return 1 }
    return coordinator.isBusy ? 0.58 : 1
  }

  @ViewBuilder
  private var idleChromeLive: some View {
    idleChromeContentLive
  }

  private var idleChromeContentLive: some View {
    HStack(spacing: RecordingLauncherIdleLayout.mainSpacing) {
      HStack(spacing: RecordingLauncherIdleLayout.mainSpacing) {
        targetModeTile(.window)
        targetModeTile(.desktop)
      }

      Divider()
        .frame(height: RecordingLauncherIdleLayout.dividerHeight)
        .opacity(0.42)

      HStack(spacing: RecordingLauncherIdleLayout.inputGroupSpacing) {
        inputTileLive(
          title: text("カメラ"),
          stateText: coordinator.isCameraEnabled ? text("オン") : text("オフ"),
          systemImage: coordinator.isCameraEnabled ? "video.fill" : "video.slash",
          isOn: coordinator.isCameraEnabled,
          showsWarning: false,
          action: { coordinator.setCameraEnabled(!coordinator.isCameraEnabled) }
        )
        inputTileLive(
          title: text("マイク"),
          stateText: coordinator.isMicrophoneEnabled ? text("オン") : text("オフ"),
          systemImage: coordinator.isMicrophoneEnabled ? "mic.fill" : "mic.slash",
          isOn: coordinator.isMicrophoneEnabled,
          showsWarning: false,
          action: { coordinator.setMicrophoneEnabled(!coordinator.isMicrophoneEnabled) }
        )
        inputTileLive(
          title: text("音声"),
          stateText: coordinator.isSystemAudioEnabled ? text("オン") : text("オフ"),
          systemImage: coordinator.isSystemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash",
          isOn: coordinator.isSystemAudioEnabled,
          showsWarning: false,
          action: { coordinator.setSystemAudioEnabled(!coordinator.isSystemAudioEnabled) }
        )
        inputTileLive(
          title: text("カーソル"),
          stateText: coordinator.isCursorCaptureEnabled ? text("オン") : text("オフ"),
          systemImage: "cursorarrow",
          isOn: coordinator.isCursorCaptureEnabled,
          showsWarning: false,
          action: { coordinator.setCursorCaptureEnabled(!coordinator.isCursorCaptureEnabled) }
        )
      }

      Spacer(minLength: RecordingLauncherIdleLayout.minFlexibleGap)

      Divider()
        .frame(height: RecordingLauncherIdleLayout.dividerHeight)
        .opacity(0.42)

      HStack(spacing: RecordingLauncherIdleLayout.auxiliaryGroupSpacing) {
        recordActionTileLive
          .layoutPriority(1)
        HStack(spacing: RecordingLauncherIdleLayout.utilityClusterSpacing) {
          recentProjectsMenuLive
          settingsLinkLive
          utilityIconButtonLive(systemImage: "xmark", title: text("終了"), action: {
            isQuitConfirmationPresented = true
          })
        }
      }
    }
    .padding(.horizontal, RecordingLauncherBarMetrics.horizontalPadding)
    .frame(height: RecordingLauncherBarMetrics.barHeight)
  }

  private func targetModeTile(_ mode: RecordingSelectionModel.TargetMode) -> some View {
    let isSelected = selectionModel.selectedSourceType == mode
    let hasSelectedTarget = isSelected && selectionModel.selectedSource != nil
    let accent = targetModeAccent(mode)
    let caption = hasSelectedTarget ? selectionModel.selectedTargetDisplayLabel : nil
    return Button {
      guard !idleInteractionLocked else { return }
      if selectionModel.selectedSourceType != mode {
        selectionModel.selectSourceType(mode)
      }
      Task { await actions.pickWindow() }
    } label: {
      VStack(spacing: RecordingLauncherIdleLayout.tileContentSpacing) {
        ZStack(alignment: .bottomTrailing) {
          Image(systemName: mode.systemImage)
            .font(.system(size: RecordingLauncherIdleLayout.targetGlyphSize, weight: .medium))

          if hasSelectedTarget {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(accent)
              .offset(x: 5, y: 4)
          }
        }
        .frame(height: 18)

        Text(targetModeTitle(mode))
          .font(.system(size: RecordingLauncherIdleLayout.targetLabelSize, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)

        if let caption, !caption.isEmpty {
          Text(caption)
            .font(.system(size: RecordingLauncherIdleLayout.targetCaptionSize, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: RecordingLauncherIdleLayout.targetTileWidth - 8)
        }
      }
      .foregroundStyle(hasSelectedTarget ? accent : .secondary)
      .padding(.horizontal, RecordingLauncherIdleLayout.tileHorizontalInset)
      .frame(width: RecordingLauncherIdleLayout.targetTileWidth, height: RecordingLauncherIdleLayout.tileHeight)
      .launcherTileChrome(
        isActive: hasSelectedTarget,
        isWarning: false,
        tint: hasSelectedTarget ? accent : nil
      )
    }
    .buttonStyle(.plain)
    .disabled(idleInteractionLocked)
    .help(targetModeHelp(mode, isSelected: isSelected))
    .accessibilityLabel(targetModeAccessibilityLabel(mode, caption: caption))
    .accessibilityHint(targetModeHelp(mode, isSelected: isSelected))
  }

  private func inputTileLive(
    title: String,
    stateText: String,
    systemImage: String,
    isOn: Bool,
    showsWarning: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      guard !idleInteractionLocked else { return }
      action()
    } label: {
      LauncherLabeledTile(
        systemImage: systemImage,
        title: title,
        foreground: isOn ? Color.primary : .secondary,
        width: RecordingLauncherIdleLayout.inputTileWidth,
        isActive: isOn,
        isWarning: showsWarning
      )
    }
    .buttonStyle(.plain)
    .disabled(idleInteractionLocked)
    .help("\(title) \(stateText)")
    .accessibilityLabel("\(title), \(stateText)")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  private var recordActionTileLive: some View {
    Button(action: actions.record) {
      LauncherRecordTile(
        systemImage: recordActionSystemImage,
        title: recordActionShortTitle,
        isEnabled: recordActionEnabled,
        isReady: recordActionEnabled && hasSelectedRecordTarget,
        tint: recordActionTint
      )
    }
    .buttonStyle(.plain)
    .disabled(!recordActionEnabled)
    .help(recordActionHelp)
    .accessibilityLabel(recordActionTitle)
    .accessibilityHint(recordActionHelp)
    .accessibilityAddTraits(recordActionEnabled ? [] : .isStaticText)
  }

  private var recordActionShortTitle: String {
    if hasSelectedRecordTarget {
      return text(RecordingLauncherCopyKey.recordTileLabel)
    }
    return text(RecordingLauncherCopyKey.selectTargetTileLabel)
  }

  private var recentProjectsMenuLive: some View {
    Menu {
      if recentProjects.isEmpty {
        Text(text(RecordingLauncherCopyKey.noRecordingsYet))
      } else {
        ForEach(recentProjects) { project in
          Menu {
            Button(text(RecordingLauncherCopyKey.openRecentRecording)) {
              actions.openProject(project.id)
            }
            Button(text(RecordingLauncherCopyKey.revealInFinder)) {
              actions.revealProjectInFinder(project.id)
            }
            Button(text(RecordingLauncherCopyKey.deleteRecording), role: .destructive) {
              projectPendingDeleteID = project.id
            }
          } label: {
            Text(localizedProjectTitle(project))
          }
        }
        Divider()
        Button(text(RecordingLauncherCopyKey.openProjectLibrary)) {
          actions.openProjectLibrary()
        }
      }
    } label: {
      LauncherLabeledTile(
        systemImage: "clock.arrow.circlepath",
        title: text(RecordingLauncherCopyKey.recentRecordingsTileLabel),
        foreground: recentProjects.isEmpty ? Color.secondary.opacity(0.55) : .secondary,
        isDisabled: recentProjects.isEmpty
      )
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .disabled(idleInteractionLocked || recentProjects.isEmpty)
    .help(text(RecordingLauncherCopyKey.recentRecordingsHelp))
    .accessibilityLabel(text(RecordingLauncherCopyKey.recentRecordingsAccessibility))
  }

  private var settingsLinkLive: some View {
    SettingsLink {
      LauncherIconTile(systemImage: "gearshape", foreground: .secondary)
    }
    .buttonStyle(.plain)
    .help(text("設定"))
    .accessibilityLabel(text("設定"))
    .accessibilityHint(text("設定"))
  }

  private func launcherAuxiliaryIconControl(
    systemImage: String,
    title: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      LauncherIconTile(systemImage: systemImage, foreground: .secondary)
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(title)
    .accessibilityHint(help)
  }

  private func utilityIconButtonLive(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
    launcherAuxiliaryIconControl(
      systemImage: systemImage,
      title: title,
      help: title,
      action: action
    )
  }

  private var idleInteractionLocked: Bool {
    coordinator.isBusy || coordinator.state == .recording || coordinator.state == .armed
  }

  private var recordActionEnabled: Bool {
    if coordinator.state == .failed { return false }
    if coordinator.isBusy { return false }
    if shouldRequireScreenRecordingPreflightForLauncher && !ScreenCaptureAccess.missingCriticalPermissions().isEmpty { return false }
    return true
  }

  private var shouldRequireScreenRecordingPreflightForLauncher: Bool {
    guard let source = selectionModel.selectedSource else { return true }
    switch source {
    case .systemPickerSelection:
      return false
    }
  }

  private var hasSelectedRecordTarget: Bool {
    selectionModel.selectedSource != nil
  }

  private var recordActionTitle: String {
    if hasSelectedRecordTarget {
      return text("録画開始")
    }
    switch selectionModel.selectedSourceType {
    case .window: return text("ウィンドウ選択")
    case .desktop: return text("画面を選択")
    }
  }

  private var recordActionSystemImage: String {
    hasSelectedRecordTarget ? "record.circle.fill" : "cursorarrow.click"
  }

  private var recordActionTint: Color? {
    guard recordActionEnabled else { return nil }
    return hasSelectedRecordTarget ? LauncherLiquidGlassColor.record : LauncherLiquidGlassColor.selection
  }

  private var recordActionHelp: String {
    if !recordActionEnabled {
      return text("権限または現在の状態を確認してください")
    }
    if hasSelectedRecordTarget {
      return text("録画を開始")
    }
    switch selectionModel.selectedSourceType {
    case .window: return text("録るウィンドウを選択")
    case .desktop: return text("録るデスクトップを選択")
    }
  }

  private func targetModeTitle(_ mode: RecordingSelectionModel.TargetMode) -> String {
    switch mode {
    case .window: return text("ウィンドウ")
    case .desktop: return text("デスクトップ")
    }
  }

  private func targetModeAccent(_ mode: RecordingSelectionModel.TargetMode) -> Color {
    switch mode {
    case .window: return LauncherLiquidGlassColor.selection
    case .desktop: return LauncherLiquidGlassColor.selection
    }
  }

  private func targetModeHelp(_ mode: RecordingSelectionModel.TargetMode, isSelected: Bool) -> String {
    if isSelected, selectionModel.selectedSource != nil {
      return text("録る対象を変更")
    }
    switch mode {
    case .window: return text("録るウィンドウを選択")
    case .desktop: return text("録るディスプレイを選択")
    }
  }

  private func targetModeAccessibilityLabel(
    _ mode: RecordingSelectionModel.TargetMode,
    caption: String?
  ) -> String {
    let title = targetModeTitle(mode)
    if let caption, !caption.isEmpty {
      return "\(title), \(caption)"
    }
    return title
  }

  private var recordingChromeLive: some View {
    HStack(spacing: 10) {
      recordingStatusCompactLive
      Spacer(minLength: 0)

      Button {
        Task { await actions.stopRecording() }
      } label: {
        recordingStopButtonLabel
      }
      .buttonStyle(.plain)
      .disabled(!coordinator.canStopRecording)
      .accessibilityLabel(text("停止"))
    }
    .padding(.horizontal, RecordingLauncherBarMetrics.horizontalPadding)
    .onAppear { isRecordingPulseActive = true }
    .onDisappear { isRecordingPulseActive = false }
  }

  private var recordingStatusCompactLive: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(LauncherLiquidGlassColor.record)
        .frame(width: 8, height: 8)
        .scaleEffect(isRecordingPulseActive ? 1.22 : 0.88)
        .opacity(isRecordingPulseActive ? 1 : 0.55)
        .animation(
          isRecordingPulseActive
            ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
            : .default,
          value: isRecordingPulseActive
        )
      Text(RecordingLauncherElapsedFormatter.mmss(from: coordinator.recordingElapsedSeconds))
        .font(.system(size: 13, weight: .bold, design: .monospaced))
        .monospacedDigit()
    }
    .foregroundStyle(Color.primary)
    .frame(width: 74, height: 28)
    .launcherPlainCapsuleBackground(isProminent: false)
    .help("\(text("録画中")): \(RecordingLauncherElapsedFormatter.mmss(from: coordinator.recordingElapsedSeconds))")
  }

  private var recordingStopButtonLabel: some View {
    Label(text("停止"), systemImage: "stop.fill")
      .font(.system(size: 11, weight: .bold))
      .lineLimit(1)
      .foregroundStyle(Color.primary)
      .padding(.horizontal, 9)
      .frame(width: 68, height: 28)
      .launcherPlainCapsuleBackground(isProminent: true)
  }

  private var postStopChromeLive: some View {
    HStack(alignment: .center, spacing: RecordingLauncherBarMetrics.interGroupSpacing) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 0) {
        Text(text(RecordingLauncherCopyKey.openingEditorPrimary))
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(text(RecordingLauncherCopyKey.openingEditorSecondary))
          .font(.system(size: 10.25, weight: .regular))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      ProgressView()
        .scaleEffect(0.65)
        .frame(width: 18, height: 18)
        .opacity(coordinator.isFinalizingStoppedRecording ? 1 : 0)

      Button(action: actions.openEditorNow) {
        Text(text(RecordingLauncherCopyKey.openNow))
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(.secondary)
          .underline()
          .lineLimit(1)
          .padding(.horizontal, RecordingLauncherManualOpenStyle.horizontalPadding)
          .padding(.vertical, RecordingLauncherManualOpenStyle.verticalPadding)
      }
      .launcherSystemGlassButton()
      .accessibilityLabel(text(RecordingLauncherCopyKey.openNow))
    }
    .padding(.horizontal, RecordingLauncherBarMetrics.horizontalPadding)
  }

  private func text(_ key: String) -> String {
    languageStore.localized(key)
  }

  private func localizedProjectTitle(_ summary: ProjectStore.ProjectSummary) -> String {
    languageStore.localizedProjectDisplayTitle(
      storedTitle: summary.title,
      createdAt: summary.createdAt
    )
  }
}

private extension View {
  @ViewBuilder
  func launcherSystemGlassButton(tint: Color? = nil, prominent: Bool = false) -> some View {
    if prominent {
      self.buttonStyle(.glassProminent)
        .controlSize(.small)
        .tint(tint)
    } else if let tint {
      self.buttonStyle(.glass(.regular.tint(tint)))
        .controlSize(.small)
    } else {
      self.buttonStyle(.glass)
        .controlSize(.small)
    }
  }

  @ViewBuilder
  func launcherGlassBackground(tint: Color? = nil, cornerRadius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    self.background {
      if let tint {
        Color.clear.glassEffect(.clear.tint(tint), in: shape)
      } else {
        Color.clear.glassEffect(.clear, in: shape)
      }
    }
  }

  @ViewBuilder
  func launcherUnifiedGlassSurface() -> some View {
    let shape = RoundedRectangle(
      cornerRadius: RecordingLauncherBarMetrics.cornerRadius,
      style: .continuous
    )
    GlassEffectContainer(spacing: 4) {
      self.glassEffect(.clear.interactive(), in: shape)
    }
    .overlay {
      shape
        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        .blendMode(.overlay)
    }
    .overlay {
      shape
        .strokeBorder(.black.opacity(0.04), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
  }

  func launcherTileChrome(
    isActive: Bool,
    isWarning: Bool,
    isDisabled: Bool = false,
    isAwaitingTarget: Bool = false,
    tint: Color? = nil,
    cornerRadius: CGFloat = RecordingLauncherIdleLayout.tileCornerRadius
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return self
      .background {
        if isWarning {
          Color.clear.glassEffect(
            .clear.tint(LauncherLiquidGlassColor.warning.opacity(0.14)),
            in: shape
          )
        } else if let tint, isActive {
          Color.clear.glassEffect(.clear.tint(tint.opacity(0.20)).interactive(), in: shape)
        } else if isActive {
          Color.clear.glassEffect(.clear.interactive(), in: shape)
        } else {
          Color.clear.glassEffect(.clear, in: shape)
        }
      }
      .overlay {
        if isAwaitingTarget {
          shape.strokeBorder(Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
      }
      .clipShape(shape)
      .contentShape(shape)
      .opacity(isDisabled ? 0.36 : 1)
      .saturation(isDisabled ? 0.15 : 1)
  }

  func launcherPlainTileBackground(
    isActive: Bool,
    isWarning: Bool,
    tint: Color? = nil,
    cornerRadius: CGFloat = RecordingLauncherIdleLayout.tileCornerRadius
  ) -> some View {
    self.launcherTileChrome(
      isActive: isActive,
      isWarning: isWarning,
      tint: tint,
      cornerRadius: cornerRadius
    )
  }

  func launcherPlainCapsuleBackground(isProminent: Bool = false, isDestructive: Bool = false) -> some View {
    let shape = Capsule(style: .continuous)
    return self.background {
      if isProminent {
        Color.clear.glassEffect(
          .clear.tint(LauncherLiquidGlassColor.record.opacity(0.16)).interactive(),
          in: shape
        )
      } else {
        Color.clear.glassEffect(.clear, in: shape)
      }
    }
    .contentShape(shape)
  }
}
