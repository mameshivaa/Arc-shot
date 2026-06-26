import Foundation
import Observation
import ScreenCaptureKit
import SwiftUI

/// 録画対象の選択状態（メインの `RecordView` とフローティングランチャーで共有）。
@MainActor
@Observable
final class RecordingSelectionModel {
  enum TargetMode: String, CaseIterable, Identifiable {
    case window
    case desktop

    var id: String { rawValue }

    var shortLabel: String {
      switch self {
      case .window: return "Window"
      case .desktop: return "Desktop"
      }
    }

    var cardTitle: String {
      switch self {
      case .window: return "ウィンドウを録る"
      case .desktop: return "デスクトップを録る"
      }
    }

    var pickerAccessibilityHint: String {
      switch self {
      case .window: return "アプリの特定ウィンドウを収録対象にします"
      case .desktop: return "選択したディスプレイ全体を収録対象にします"
      }
    }

    var systemImage: String {
      switch self {
      case .window: return "macwindow"
      case .desktop: return "display"
      }
    }
  }

  var selectedSourceType: TargetMode = .window
  var selectedSystemPickerSelection: CaptureSource.SystemPickerSelection?

  private var systemPickerSources: [CaptureSource] {
    selectedSystemPickerSelection.map { [CaptureSource.systemPickerSelection($0)] } ?? []
  }

  var sources: [CaptureSource] {
    systemPickerSources
  }

  var selectedSource: CaptureSource? {
    selectedSystemPickerSelection.map(CaptureSource.systemPickerSelection)
  }

  var selectedSourceShortTitle: String {
    guard let source = selectedSource else { return "未選択" }
    switch source {
    case .systemPickerSelection(let selection):
      return selection.displayName
    }
  }

  var selectedTargetDisplayLabel: String {
    selectedSystemPickerSelection?.displayName ?? ""
  }

  var selectedSourceRecordingLabel: String? {
    selectedSystemPickerSelection?.displayName
  }

  func syncSelectedSourceIDWithSources() {
    guard let source = selectedSource else { return }
    selectedSourceType = targetMode(for: source)
  }

  func selectSourceType(_ sourceType: TargetMode) {
    selectedSourceType = sourceType
    selectedSystemPickerSelection = nil
  }

  func targetMode(for source: CaptureSource) -> TargetMode {
    switch source {
    case .systemPickerSelection(let selection):
      return selection.style == .display ? .desktop : .window
    }
  }

  func preferredSource(for sourceType: TargetMode) -> CaptureSource? {
    switch sourceType {
    case .window:
      return systemPickerSources.first {
        if case .systemPickerSelection(let selection) = $0 {
          return selection.style == .window
        }
        return false
      }
    case .desktop:
      return systemPickerSources.first {
        if case .systemPickerSelection(let selection) = $0 {
          return selection.style == .display
        }
        return false
      }
    }
  }

  func applySelectedSource(_ source: CaptureSource) {
    selectedSourceType = targetMode(for: source)
    switch source {
    case .systemPickerSelection(let selection):
      selectedSystemPickerSelection = selection
    }
  }

  func applySystemPickerSelection(_ selection: CaptureSource.SystemPickerSelection) {
    selectedSourceType = selection.style == .display ? .desktop : .window
    selectedSystemPickerSelection = selection
  }
}
