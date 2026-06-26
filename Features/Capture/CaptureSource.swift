import Foundation
import ScreenCaptureKit

enum CaptureSource: Identifiable, Hashable {
  struct SystemPickerSelection: Hashable {
    var id: String
    var style: SCShareableContentStyle
    var filter: SCContentFilter
    var displayName: String
    var contentRect: CGRect
    var pointPixelScale: Float

    static func == (lhs: SystemPickerSelection, rhs: SystemPickerSelection) -> Bool {
      lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(id)
    }
  }

  case systemPickerSelection(SystemPickerSelection)

  var id: String {
    switch self {
    case .systemPickerSelection(let selection):
      return selection.id
    }
  }

  var title: String {
    switch self {
    case .systemPickerSelection(let selection):
      return selection.displayName
    }
  }
}
