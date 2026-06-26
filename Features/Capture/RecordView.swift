import ScreenCaptureKit
import SwiftUI

struct RecordView: View {
  private enum UIConstants {
    static let sourceTypeCardCornerRadius: CGFloat = 12
    static let sourceTypeCardMinHeight: CGFloat = 76
    static let sourceTypeCardSelectedBorderWidth: CGFloat = 2
    static let sourceTypeCardDefaultBorderWidth: CGFloat = 1
    static let stopButtonMinWidth: CGFloat = 220
    static let recordingDotSize: CGFloat = 12
    static let recordingPulseScaleExpanded: CGFloat = 1.25
    static let recordingPulseScaleCompact: CGFloat = 0.9
    static let recordingPulseOpacityExpanded: Double = 0.95
    static let recordingPulseOpacityCompact: Double = 0.45
    static let recordingPulseDurationSeconds: Double = 0.9
    static let recordingSurfaceCornerRadius: CGFloat = 16
    static let recordingSurfacePadding: CGFloat = 28
    static let recordingSurfaceBackgroundOpacity: Double = 0.1
  }

  @Environment(RecordingSelectionModel.self) private var recordingSelection
  @Environment(RecordingCoordinator.self) private var coordinator
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(WorkflowNavigator.self) private var workflowNav

  @State private var countdownRemaining: Int?
  @State private var countdownTask: Task<Void, Never>?
  @State private var isRecordingPulseExpanded = false

  private var selectedSource: CaptureSource? {
    recordingSelection.selectedSource
  }

  private var canRecordSelectedSource: Bool {
    selectedSource != nil
  }

  private var isRecordingActive: Bool {
    coordinator.state == .recording || coordinator.state == .armed
  }

  private var selectedSourceTitle: String {
    selectedSource?.title ?? languageStore.localized("未選択")
  }

  private var hasCriticalPermissionBlocker: Bool {
    guard let selectedSource else {
      return !ScreenCaptureAccess.missingCriticalPermissions().isEmpty
    }
    switch selectedSource {
    case .systemPickerSelection:
      return false
    }
  }

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: AppUIMetrics.contentSpacing) {
        developerHintBanner

        headerRow

        if isRecordingActive {
          recordingActiveView
        } else {
          captureInputView
        }

        if let msg = coordinator.lastErrorMessage {
          Text(msg)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }

        if let msg = projectStore.lastErrorMessage {
          Text(msg)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }

        if !isRecordingActive {
          Spacer()
        }
      }

      if let countdownRemaining {
        CountdownOverlay(secondsRemaining: countdownRemaining)
          .transition(.opacity)
      }
    }
    .onAppear {
      coordinator.reconcileInteractionStateForRecordUI()
    }
    .onChange(of: isRecordingActive) { _, active in
      isRecordingPulseExpanded = active
    }
    .onDisappear {
      countdownTask?.cancel()
      countdownTask = nil
    }
    .onChange(of: coordinator.lastErrorMessage) { _, msg in
      guard let msg else { return }
      alertCenter.present(msg)
    }
    .onChange(of: projectStore.lastErrorMessage) { _, msg in
      guard let msg else { return }
      alertCenter.present(msg)
    }
  }

  private var developerHintBanner: some View {
    Text("開発・検証向けキャプチャ画面です。ユーザー向けの録画開始は画面上のフローティング録画バーから行います（⌘⇧L）。")
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.vertical, 6)
      .padding(.horizontal, 10)
      .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var headerRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("キャプチャ（開発ツール）")
        .font(.largeTitle.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      Spacer()

      EmptyView()
    }
  }

  private var captureInputView: some View {
    VStack(alignment: .leading, spacing: AppUIMetrics.contentSpacing) {
      PermissionsGateView()

      GroupBox("録画対象") {
        VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
          sourceSelectionDetailView
        }
        .padding(.vertical, 6)
      }

      GroupBox("収録オプション") {
        VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
          Toggle("マイク", isOn: Binding(
            get: { coordinator.isMicrophoneEnabled },
            set: { coordinator.setMicrophoneEnabled($0) }
          ))
          .disabled(coordinator.isBusy || isRecordingActive)
          .help("マイクとシステム音声を同時に収録できます")

          Toggle("システム音声", isOn: Binding(
            get: { coordinator.isSystemAudioEnabled },
            set: { coordinator.setSystemAudioEnabled($0) }
          ))
          .disabled(coordinator.isBusy || isRecordingActive)

          Toggle("カーソル情報を記録", isOn: Binding(
            get: { coordinator.isCursorCaptureEnabled },
            set: { coordinator.setCursorCaptureEnabled($0) }
          ))
          .disabled(coordinator.isBusy || isRecordingActive)

          Toggle("カメラ（PiP別ファイル）", isOn: Binding(
            get: { coordinator.isCameraEnabled },
            set: { coordinator.setCameraEnabled($0) }
          ))
          .disabled(coordinator.isBusy || isRecordingActive)
        }
        .padding(.vertical, 6)
      }

      HStack(spacing: AppUIMetrics.groupSpacing) {
        Button {
          guard let selectedSource else { return }
          startCountdownThenRecord(selectedSource: selectedSource)
        } label: {
          Text("録画を開始")
            .frame(minWidth: 140)
        }
        .disabled(coordinator.isBusy || !canRecordSelectedSource || isRecordingActive || countdownRemaining != nil || hasCriticalPermissionBlocker)
        .accessibilityLabel("録画を開始")
        .accessibilityHint("カウントダウンのあとキャプチャを開始します")

        Text(languageStore.localizedFormat("選択中: %@", selectedSourceTitle))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer()
      }
    }
  }

  @ViewBuilder
  private var sourceSelectionDetailView: some View {
    HStack(spacing: AppUIMetrics.groupSpacing) {
      Label(selectedSourceTitle, systemImage: recordingSelection.selectedSourceType.systemImage)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      Button("OS ピッカーで選択") {
        coordinator.setFloatingLauncherVisible(true)
      }
      .disabled(coordinator.isBusy || isRecordingActive)
      .accessibilityLabel("録画対象をOSピッカーで選択")
    }
    Text("録画対象の確定は macOS の共有ピッカーで行います。")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func sourceTypeCard(_ sourceType: RecordingSelectionModel.TargetMode) -> some View {
    let isSelected = recordingSelection.selectedSourceType == sourceType
    let backgroundColor = isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)
    let borderColor = isSelected ? Color.accentColor : Color.secondary.opacity(0.25)
    let borderWidth = isSelected ? UIConstants.sourceTypeCardSelectedBorderWidth : UIConstants.sourceTypeCardDefaultBorderWidth

    return Button {
      recordingSelection.selectSourceType(sourceType)
    } label: {
      HStack(alignment: .center, spacing: AppUIMetrics.tightSpacing) {
        Image(systemName: sourceType.systemImage)
          .font(.title3)
        VStack(alignment: .leading, spacing: 2) {
          Text(languageStore.localized(sourceType.cardTitle))
            .font(.headline)
            .multilineTextAlignment(.leading)
          Text(sourceAvailabilityText(for: sourceType))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(AppUIMetrics.groupSpacing)
      .frame(maxWidth: .infinity, minHeight: UIConstants.sourceTypeCardMinHeight, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: UIConstants.sourceTypeCardCornerRadius, style: .continuous)
          .fill(backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: UIConstants.sourceTypeCardCornerRadius, style: .continuous)
          .stroke(borderColor, lineWidth: borderWidth)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(languageStore.localized(sourceType.cardTitle))
    .accessibilityHint(languageStore.localized(sourceType.pickerAccessibilityHint))
  }

  private func sourceAvailabilityText(for sourceType: RecordingSelectionModel.TargetMode) -> String {
    languageStore.localized(recordingSelection.selectedSourceType == sourceType ? "OS ピッカーで確定" : "未選択")
  }

  private var recordingActiveView: some View {
    VStack(spacing: AppUIMetrics.contentSpacing) {
      Spacer(minLength: 0)
      VStack(spacing: AppUIMetrics.groupSpacing) {
        HStack(spacing: AppUIMetrics.tightSpacing) {
          Circle()
            .fill(Color.red)
            .frame(width: UIConstants.recordingDotSize, height: UIConstants.recordingDotSize)
            .scaleEffect(isRecordingPulseExpanded ? UIConstants.recordingPulseScaleExpanded : UIConstants.recordingPulseScaleCompact)
            .opacity(isRecordingPulseExpanded ? UIConstants.recordingPulseOpacityExpanded : UIConstants.recordingPulseOpacityCompact)
            .animation(
              .easeInOut(duration: UIConstants.recordingPulseDurationSeconds).repeatForever(autoreverses: true),
              value: isRecordingPulseExpanded
            )
          Text("録画中")
            .font(.title2.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("録画中")

        Text(languageStore.localizedFormat("状態: %@", languageStore.localized(coordinator.state.localizedStatusLabel)))
          .foregroundStyle(.secondary)
          .accessibilityLabel(languageStore.localizedFormat("収録状態 %@", languageStore.localized(coordinator.state.localizedStatusLabel)))

        Button {
          stopRecordingAndCreateProject()
        } label: {
          Text("録画を停止")
            .frame(minWidth: UIConstants.stopButtonMinWidth)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(coordinator.isBusy || !isRecordingActive)
        .accessibilityLabel("収録を停止")
        .accessibilityHint("録画を終了して編集へ進みます")

        Text("⌘. で録画のみ停止できます。編集への取り込みはフローティング録画バーの停止を優先してください。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .padding(UIConstants.recordingSurfacePadding)
      .background(
        RoundedRectangle(cornerRadius: UIConstants.recordingSurfaceCornerRadius, style: .continuous)
          .fill(Color.secondary.opacity(UIConstants.recordingSurfaceBackgroundOpacity))
      )
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      isRecordingPulseExpanded = true
    }
  }

  private func startCountdownThenRecord(selectedSource: CaptureSource) {
    countdownTask?.cancel()
    countdownTask = Task { @MainActor in
      countdownRemaining = RecordingCountdown.seconds
      for i in stride(from: RecordingCountdown.seconds, through: 1, by: -1) {
        countdownRemaining = i
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if Task.isCancelled { return }
      }
      countdownRemaining = nil
      await coordinator.startRecording(source: selectedSource)
    }
  }

  private func stopRecordingAndCreateProject() {
    Task {
      await coordinator.stopRecording()
      await RecordingSessionFinalization.finalizeAfterUserStoppedRecording(
        coordinator: coordinator,
        projectStore: projectStore,
        workflowNav: workflowNav,
        alertCenter: alertCenter,
        selectedSource: recordingSelection.selectedSource
      )
    }
  }

}
