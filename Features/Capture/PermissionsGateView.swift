import SwiftUI

struct RecordingPermissionSetupView: View {
  var onCompleted: () -> Void

  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var statuses: [ScreenCaptureAccess.PermissionStatus] = []
  @State private var restartNeeded = false
  @State private var restartErrorMessage: String?
  @State private var isRequesting: ScreenCaptureAccess.Permission?
  @State private var didLoadStatuses = false

  private var isComplete: Bool {
    screenRecordingState.isGranted
  }

  private var screenRecordingState: ScreenCaptureAccess.PermissionState {
    statuses.first { $0.permission == .screenRecording }?.state ?? .denied
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 8) {
        Text("録画を始める前に")
          .font(.largeTitle.weight(.bold))
        Text("画面収録は録画に必要です。マイクとカメラは任意で、必要になった時に許可できます。")
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 12) {
        ForEach(statuses) { status in
          permissionRow(status)
        }
      }

      if restartNeeded {
        restartNotice
      }

      if let restartErrorMessage {
        Text(languageStore.localizedFormat("再起動できませんでした。ArcShotを終了して再度開いてください。%@", restartErrorMessage))
          .font(.callout)
          .foregroundStyle(.red)
      }

      HStack {
        Button("再チェック") {
          refresh()
        }
        .buttonStyle(.bordered)

        Spacer()

        Button("ArcShotを開始") {
          onCompleted()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isComplete || restartNeeded)
      }
    }
    .padding(40)
    .frame(maxWidth: 760, maxHeight: .infinity, alignment: .center)
    .onAppear {
      refresh()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      refresh()
    }
  }

  private func permissionRow(_ status: ScreenCaptureAccess.PermissionStatus) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: iconName(for: status.state))
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(stateColor(status.state))
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(text(status.permission.title))
          .font(.headline)
        Text(rowDescription(for: status))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text(stateLabel(status.state))
        .font(.caption.weight(.semibold))
        .foregroundStyle(stateColor(status.state))

      actionButton(for: status)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.primary.opacity(0.055))
    )
  }

  @ViewBuilder
  private func actionButton(for status: ScreenCaptureAccess.PermissionStatus) -> some View {
    switch status.state {
    case .granted:
      EmptyView()
    case .notDetermined:
      Button(isRequesting == status.permission ? text("確認中…") : requestTitle(for: status.permission)) {
        Task { await request(status.permission) }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isRequesting != nil)
    case .denied, .unavailable:
      Button(text("設定を開く")) {
        ScreenCaptureAccess.openSettings(for: status.permission)
      }
      .buttonStyle(.bordered)
    }
  }

  private var restartNotice: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("画面収録の許可を反映するため、ArcShotを再起動してください。", systemImage: "arrow.clockwise.circle.fill")
        .font(.callout.weight(.semibold))
      Button("ArcShotを再起動") {
        ScreenCaptureAccess.restartApplication { message in
          restartErrorMessage = message
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.orange.opacity(0.14))
    )
  }

  private func request(_ permission: ScreenCaptureAccess.Permission) async {
    isRequesting = permission
    let previous = state(for: permission)
    let newState = await ScreenCaptureAccess.requestPermission(permission)
    isRequesting = nil
    refresh()
    if permission == .screenRecording, previous != .granted, newState == .granted {
      restartNeeded = true
    }
  }

  private func refresh() {
    let previousScreenState = state(for: .screenRecording)
    statuses = ScreenCaptureAccess.recordingSetupStatuses()
    let currentScreenState = statuses.first { $0.permission == .screenRecording }?.state ?? .denied
    if didLoadStatuses, previousScreenState != .granted, currentScreenState == .granted {
      restartNeeded = true
    }
    didLoadStatuses = true
  }

  private func state(for permission: ScreenCaptureAccess.Permission) -> ScreenCaptureAccess.PermissionState {
    statuses.first { $0.permission == permission }?.state ?? .denied
  }

  private func requestTitle(for permission: ScreenCaptureAccess.Permission) -> String {
    switch permission {
    case .screenRecording:
      text("確認する")
    case .microphone, .camera:
      text("許可する")
    case .accessibility, .speechRecognition:
      text("確認する")
    }
  }

  private func rowDescription(for status: ScreenCaptureAccess.PermissionStatus) -> String {
    switch status.permission {
    case .screenRecording:
      return text("ウィンドウやデスクトップを収録するために必要です。")
    case .microphone:
      return text("ナレーションや声を録る場合に使います。")
    case .camera:
      return text("カメラ映像を別トラックとして録る場合に使います。")
    case .accessibility:
      return text("今回は初回セットアップ対象外です。")
    case .speechRecognition:
      return text("今回は初回セットアップ対象外です。")
    }
  }

  private func stateLabel(_ state: ScreenCaptureAccess.PermissionState) -> String {
    switch state {
    case .granted: return text("許可済み")
    case .notDetermined: return text("未確認")
    case .denied: return text("未許可")
    case .unavailable: return text("利用不可")
    }
  }

  private func stateColor(_ state: ScreenCaptureAccess.PermissionState) -> Color {
    switch state {
    case .granted: return .green
    case .notDetermined: return .secondary
    case .denied: return .orange
    case .unavailable: return .red
    }
  }

  private func iconName(for state: ScreenCaptureAccess.PermissionState) -> String {
    switch state {
    case .granted: return "checkmark.circle.fill"
    case .notDetermined: return "questionmark.circle"
    case .denied: return "exclamationmark.triangle.fill"
    case .unavailable: return "xmark.octagon.fill"
    }
  }

  private func text(_ key: String) -> String {
    languageStore.localized(key)
  }
}

struct PermissionsGateView: View {
  @Environment(AppLanguageStore.self) private var languageStore
  @State private var statuses: [ScreenCaptureAccess.PermissionStatus] = []

  var body: some View {
    GroupBox("権限チェック") {
      VStack(alignment: .leading, spacing: AppUIMetrics.tightSpacing) {
        if statuses.isEmpty {
          Text("権限情報を読み込み中…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        ForEach(statuses) { status in
          HStack(alignment: .firstTextBaseline, spacing: AppUIMetrics.tightSpacing) {
            Text(languageStore.localized(status.permission.title))
              .font(.subheadline.weight(.semibold))
              .frame(width: 110, alignment: .leading)
            Text(stateLabel(status.state))
              .font(.caption)
              .foregroundStyle(stateColor(status.state))
            Spacer()
            Button(languageStore.localized("設定を開く")) {
              ScreenCaptureAccess.openSettings(for: status.permission)
            }
            .buttonStyle(.bordered)
          }
        }

        if hasCriticalBlocker {
          Text("画面収録が未許可のため、録画を開始できません。先に「設定を開く」から許可してください。")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .padding(.vertical, 4)
    }
    .onAppear {
      refresh()
    }
  }

  var hasCriticalBlocker: Bool {
    statuses.contains { status in
      status.permission == .screenRecording && !status.state.isGranted
    }
  }

  func refresh() {
    statuses = ScreenCaptureAccess.permissionStatuses()
  }

  private func stateLabel(_ state: ScreenCaptureAccess.PermissionState) -> String {
    switch state {
    case .granted:
      languageStore.localized("許可済み")
    case .notDetermined:
      languageStore.localized("未確認")
    case .denied:
      languageStore.localized("未許可")
    case .unavailable:
      languageStore.localized("利用不可")
    }
  }

  private func stateColor(_ state: ScreenCaptureAccess.PermissionState) -> Color {
    switch state {
    case .granted:
      .green
    case .notDetermined:
      .secondary
    case .denied:
      .orange
    case .unavailable:
      .red
    }
  }
}
