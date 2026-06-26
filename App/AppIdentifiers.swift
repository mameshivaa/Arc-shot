import Foundation

/// アプリ固有の Bundle ID／UserDefaults／キューなどの安定した識別子（散乱防止）。
enum AppIdentifiers {
  enum UserDefaultsKeys {
    static let stylePresetID = "dev.arcshot.stylePresetID"
    static let introFadeSeconds = "dev.arcshot.newProject.introFadeSeconds"
    static let outroFadeSeconds = "dev.arcshot.newProject.outroFadeSeconds"
    static let softZoomScale = "dev.arcshot.newProject.softZoomScale"
    static let windowStageFraming = "dev.arcshot.newProject.windowStageFraming"
    static let reviewLoopTrimSelection = "dev.arcshot.review.loopTrimSelection"
    static let recordingPermissionIntroCompleted = "dev.arcshot.recordingPermissionIntroCompleted"
    static let appLanguage = "dev.arcshot.appLanguage"
    static let editorTimelinePaneHeight = "dev.arcshot.editor.timelinePaneHeight"
  }

  enum DispatchQueueLabels {
    static let capture = "dev.arcshot.capture.queue"
    static let audio = "dev.arcshot.audio.queue"
    static let export = "dev.arcshot.export.queue"
    static let recordingWriterIO = "dev.arcshot.recording.writer.io"
    static let microphone = "dev.arcshot.microphone.queue"
  }

  enum TempFilePrefix {
    static let recording = "arcshot-"
    static let camera = "arcshot-camera-"
  }

  enum CaptureNotifications {
    static let cameraPresentationChanged = Notification.Name("dev.arcshot.capture.cameraPresentationChanged")
  }

  enum ApplicationSupport {
    static let appFolderName = "ArcShot"
    static let projectsFolderName = "Projects"
  }
}
