import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case japanese = "ja"
  case english = "en"

  var id: String { rawValue }

  var locale: Locale {
    Locale(identifier: rawValue)
  }

  var displayName: String {
    switch self {
    case .japanese: return "Japanese"
    case .english: return "English"
    }
  }
}

@MainActor
@Observable
final class AppLanguageStore {
  private let defaults: UserDefaults

  var language: AppLanguage {
    didSet {
      defaults.set(language.rawValue, forKey: AppIdentifiers.UserDefaultsKeys.appLanguage)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.string(forKey: AppIdentifiers.UserDefaultsKeys.appLanguage)
    language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .english
  }

  var locale: Locale {
    language.locale
  }

  func localized(_ key: String) -> String {
    guard
      let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
    return bundle.localizedString(forKey: key, value: key, table: nil)
  }

  func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: locale, arguments: arguments)
  }

  func localizedProjectDisplayTitle(storedTitle: String, createdAt: Date) -> String {
    RecordingProject.localizedDisplayTitle(
      storedTitle: storedTitle,
      createdAt: createdAt,
      recordingLabel: localized("収録"),
      locale: locale
    )
  }
}

struct AppLanguageSettingsView: View {
  @Environment(AppLanguageStore.self) private var languageStore

  var body: some View {
    @Bindable var languageStore = languageStore
    Form {
      Picker(languageStore.localized("Display Language"), selection: $languageStore.language) {
        ForEach(AppLanguage.allCases) { language in
          Text(languageStore.localized(language.displayName)).tag(language)
        }
      }
      .pickerStyle(.radioGroup)

      Text(languageStore.localized("Changes apply immediately to the app UI, menus, and recording bar."))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(AppUIMetrics.rootPadding)
    .frame(width: 420)
    .environment(\.locale, languageStore.locale)
    .id(languageStore.language)
  }
}

struct AppLocalizedRoot<Content: View>: View {
  @Environment(AppLanguageStore.self) private var languageStore
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .environment(\.locale, languageStore.locale)
      .id(languageStore.language)
  }
}
