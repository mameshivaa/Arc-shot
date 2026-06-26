import SwiftUI

@main
struct ArcShotApp: App {
  @NSApplicationDelegateAdaptor(ArcShotApplicationDelegate.self) private var appDelegate

  private let runtime = ArcShotRuntime.shared

  var body: some Scene {
    Settings {
      AppLanguageSettingsView()
        .environment(runtime.languageStore)
    }
    .commands {
      ArcShotCommands(
        languageStore: runtime.languageStore,
        navigator: runtime.workflowNavigator,
        projectStore: runtime.projectStore,
        recordingCoordinator: runtime.recordingCoordinator
      )
    }
  }
}
