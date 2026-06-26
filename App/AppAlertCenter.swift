import Foundation
import Observation

@MainActor
@Observable
final class AppAlertCenter {
  struct AlertMessage: Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var message: String
  }

  var current: AlertMessage?

  func present(title: String = "ArcShot", _ message: String) {
    let languageStore = ArcShotRuntime.shared.languageStore
    current = AlertMessage(title: languageStore.localized(title), message: languageStore.localized(message))
  }
}
