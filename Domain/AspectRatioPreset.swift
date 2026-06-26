import Foundation

enum AspectRatioPreset: String, Codable, CaseIterable, Identifiable {
  case sixteenNine
  case nineSixteen
  case oneOne
  case fourThree
  case threeFour

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sixteenNine: return "16:9"
    case .nineSixteen: return "9:16"
    case .oneOne: return "1:1"
    case .fourThree: return "4:3"
    case .threeFour: return "3:4"
    }
  }
}
