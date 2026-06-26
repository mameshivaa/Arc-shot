import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Speech

/// 画面収録（ScreenCaptureKit / TCC）まわりのヘルパ。
enum ScreenCaptureAccess {
  enum Permission: CaseIterable, Identifiable {
    case screenRecording
    case microphone
    case camera
    case accessibility
    case speechRecognition

    var id: String { title }

    var title: String {
      switch self {
      case .screenRecording: return "画面収録"
      case .microphone: return "マイク"
      case .camera: return "カメラ"
      case .accessibility: return "アクセシビリティ"
      case .speechRecognition: return "音声認識"
      }
    }
  }

  enum PermissionState {
    case granted
    case unavailable
    case notDetermined
    case denied

    var isGranted: Bool {
      if case .granted = self { return true }
      return false
    }
  }

  struct PermissionStatus: Identifiable {
    var permission: Permission
    var state: PermissionState

    var id: Permission { permission }
  }

  static let recordingSetupPermissions: [Permission] = [
    .screenRecording,
    .microphone,
    .camera
  ]

  private static let scStreamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
  private static let tccDeniedCode = -3801
  static let streamStoppedBySystemCode = -3821

  /// システムの画面収録許可ダイアログを試みる。
  @MainActor
  static func requestSystemPromptIfNeeded() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    return CGRequestScreenCaptureAccess()
  }

  static var screenRecordingDeniedGuide: String {
    """
    画面収録が許可されていません。

    次を試してください：
    • 「システム設定」→「プライバシーとセキュリティ」→「画面収録」→ ArcShot をオン
    • Xcode から実行中は一覧に複数項目（異なるビルドパス）があることがあります。該当するものすべてオンにする
    • オンにしたあと ArcShot を終了してから再度実行する

    以前に「許可しない」を選んだ場合：一覧で ArcShot のチェックを一度外し、再起動後に許可ダイアログが出たら許可するか、チェックを入れ直してください。
    """
  }

  static func userFacingMessage(for error: Error) -> String {
    let ns = error as NSError
    if ns.domain == scStreamErrorDomain, ns.code == tccDeniedCode {
      return screenRecordingDeniedGuide
    }
    if ns.domain == scStreamErrorDomain, ns.code == streamStoppedBySystemCode {
      return """
      録画ストリームが macOS により停止されました。

      対象ウィンドウを選び直す、システム音声をオフにする、または ArcShot を再起動してから再試行してください。
      """
    }
    if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
      return description
    }
    return String(describing: error)
  }

  @MainActor
  static func permissionStatuses() -> [PermissionStatus] {
    Permission.allCases.map { permission in
      PermissionStatus(permission: permission, state: permissionState(for: permission))
    }
  }

  @MainActor
  static func recordingSetupStatuses() -> [PermissionStatus] {
    recordingSetupPermissions.map { permission in
      PermissionStatus(permission: permission, state: permissionState(for: permission))
    }
  }

  @MainActor
  static func recordingSetupIsComplete() -> Bool {
    recordingSetupStatuses().allSatisfy(\.state.isGranted)
  }

  @MainActor
  static func requestPermission(_ permission: Permission) async -> PermissionState {
    switch permission {
    case .screenRecording:
      _ = requestSystemPromptIfNeeded()
      return permissionState(for: .screenRecording)
    case .microphone:
      await requestCaptureDeviceAccess(for: .audio)
      return permissionState(for: .microphone)
    case .camera:
      await requestCaptureDeviceAccess(for: .video)
      return permissionState(for: .camera)
    case .accessibility, .speechRecognition:
      return permissionState(for: permission)
    }
  }

  @MainActor
  static func missingCriticalPermissions() -> [PermissionStatus] {
    permissionStatuses().filter { status in
      switch status.permission {
      case .screenRecording:
        return !status.state.isGranted
      case .microphone, .camera, .accessibility, .speechRecognition:
        return false
      }
    }
  }

  @MainActor
  static func openSettings(for permission: Permission) {
    let urlString: String = switch permission {
    case .screenRecording:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    case .microphone:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case .camera:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    case .accessibility:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case .speechRecognition:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    }
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  @MainActor
  static func restartApplication(completion: @escaping @MainActor @Sendable (String?) -> Void) {
    let appURL = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
      Task { @MainActor in
        if let error {
          completion(error.localizedDescription)
          return
        }
        NSApp.terminate(nil)
      }
    }
  }

  @MainActor
  private static func permissionState(for permission: Permission) -> PermissionState {
    switch permission {
    case .screenRecording:
      return CGPreflightScreenCaptureAccess() ? .granted : .denied
    case .microphone:
      return permissionState(from: AVCaptureDevice.authorizationStatus(for: .audio))
    case .camera:
      return permissionState(from: AVCaptureDevice.authorizationStatus(for: .video))
    case .accessibility:
      return AXIsProcessTrusted() ? .granted : .denied
    case .speechRecognition:
      return permissionState(from: SFSpeechRecognizer.authorizationStatus())
    }
  }

  private static func permissionState(from status: AVAuthorizationStatus) -> PermissionState {
    switch status {
    case .authorized:
      .granted
    case .notDetermined:
      .notDetermined
    case .restricted:
      .unavailable
    case .denied:
      .denied
    @unknown default:
      .denied
    }
  }

  private static func requestCaptureDeviceAccess(for mediaType: AVMediaType) async {
    let status = AVCaptureDevice.authorizationStatus(for: mediaType)
    guard status == .notDetermined else { return }
    _ = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: mediaType) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private static func permissionState(from status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
    switch status {
    case .authorized:
      .granted
    case .notDetermined:
      .notDetermined
    case .restricted:
      .unavailable
    case .denied:
      .denied
    @unknown default:
      .denied
    }
  }
}
