import AppKit
import Foundation

struct RecordingProject: Codable, Identifiable, Equatable {
  private enum Schema {
    static let currentVersion: Int = 8
  }

  enum SourceKind: String, Codable {
    case display
    case window
    case area
  }

  struct Source: Codable, Equatable {
    var kind: SourceKind
    var displayID: UInt32?
    var windowID: UInt32?
    /// `kind == .area` のときだけ使う、対象ディスプレイ上の正規化矩形（0...1）。
    var areaXN: Double?
    var areaYN: Double?
    var areaWidthN: Double?
    var areaHeightN: Double?

    enum CodingKeys: String, CodingKey {
      case kind
      case displayID
      case windowID
      case areaXN
      case areaYN
      case areaWidthN
      case areaHeightN
    }

    init(
      kind: SourceKind,
      displayID: UInt32?,
      windowID: UInt32?,
      areaXN: Double? = nil,
      areaYN: Double? = nil,
      areaWidthN: Double? = nil,
      areaHeightN: Double? = nil
    ) {
      self.kind = kind
      self.displayID = displayID
      self.windowID = windowID
      self.areaXN = areaXN
      self.areaYN = areaYN
      self.areaWidthN = areaWidthN
      self.areaHeightN = areaHeightN
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        kind: try c.decode(SourceKind.self, forKey: .kind),
        displayID: try c.decodeIfPresent(UInt32.self, forKey: .displayID),
        windowID: try c.decodeIfPresent(UInt32.self, forKey: .windowID),
        areaXN: try c.decodeIfPresent(Double.self, forKey: .areaXN),
        areaYN: try c.decodeIfPresent(Double.self, forKey: .areaYN),
        areaWidthN: try c.decodeIfPresent(Double.self, forKey: .areaWidthN),
        areaHeightN: try c.decodeIfPresent(Double.self, forKey: .areaHeightN)
      )
    }
  }

  struct Trim: Codable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
  }

  struct ZoomKeyframe: Codable, Equatable, Identifiable {
    var id: UUID
    var startSeconds: Double
    var inEndSeconds: Double
    var outStartSeconds: Double
    var endSeconds: Double
    var scale: Double
    var anchorX: Double
    var anchorY: Double
    var targetX: Double
    var targetY: Double
    var targetWidth: Double
    var targetHeight: Double

    init(
      id: UUID = UUID(),
      startSeconds: Double,
      inEndSeconds: Double? = nil,
      outStartSeconds: Double? = nil,
      endSeconds: Double,
      scale: Double,
      anchorX: Double,
      anchorY: Double,
      targetX: Double? = nil,
      targetY: Double? = nil,
      targetWidth: Double? = nil,
      targetHeight: Double? = nil
    ) {
      self.id = id
      self.startSeconds = startSeconds
      self.inEndSeconds = inEndSeconds ?? min(endSeconds, startSeconds + max(0.001, (endSeconds - startSeconds) * 0.22))
      self.outStartSeconds = outStartSeconds ?? max(startSeconds, endSeconds - max(0.001, (endSeconds - startSeconds) * 0.22))
      self.endSeconds = endSeconds
      self.scale = RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(scale)
      self.anchorX = max(0, min(1, anchorX))
      self.anchorY = max(0, min(1, anchorY))
      let legacyRegion = RecordingProject.ZoomSegment.targetRegion(
        scale: self.scale,
        anchorX: self.anchorX,
        anchorY: self.anchorY
      )
      self.targetX = targetX ?? legacyRegion.x
      self.targetY = targetY ?? legacyRegion.y
      self.targetWidth = targetWidth ?? legacyRegion.width
      self.targetHeight = targetHeight ?? legacyRegion.height
    }
  }

  enum CursorShape: String, Codable, CaseIterable {
    case arrow
    case iBeam
    case pointingHand
    case crosshair
    case resizeLeftRight
    case resizeUpDown
    case openHand
    case closedHand
    case operationNotAllowed
    case unknown
  }

  struct CursorSample: Codable, Equatable, Identifiable {
    var id: UUID
    var timeSeconds: Double
    var x: Double
    var y: Double
    var shape: CursorShape?

    init(id: UUID = UUID(), timeSeconds: Double, x: Double, y: Double, shape: CursorShape? = nil) {
      self.id = id
      self.timeSeconds = timeSeconds
      self.x = x
      self.y = y
      self.shape = shape
    }
  }

  struct TimelineModel: Codable, Equatable {
    struct Clip: Codable, Equatable, Identifiable {
      var id: UUID
      var sourceURL: URL
      var sourceStartSeconds: Double
      var timelineStartSeconds: Double
      var durationSeconds: Double

      init(
        id: UUID = UUID(),
        sourceURL: URL,
        sourceStartSeconds: Double = 0,
        timelineStartSeconds: Double = 0,
        durationSeconds: Double = 0
      ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceStartSeconds = max(0, sourceStartSeconds)
        self.timelineStartSeconds = max(0, timelineStartSeconds)
        self.durationSeconds = max(0, durationSeconds)
      }
    }

    struct SpeedSegment: Codable, Equatable, Identifiable {
      var id: UUID
      var startSeconds: Double
      var endSeconds: Double
      var rate: Double

      init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double, rate: Double = 1) {
        self.id = id
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = max(0, endSeconds)
        self.rate = Self.clampedRate(rate)
        if self.endSeconds < self.startSeconds {
          swap(&self.startSeconds, &self.endSeconds)
        }
      }

      static func clampedRate(_ value: Double) -> Double {
        max(0.25, min(8, value))
      }
    }

    var clips: [Clip]
    var speedSegments: [SpeedSegment]

    init(clips: [Clip] = [], speedSegments: [SpeedSegment] = []) {
      self.clips = clips.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
      self.speedSegments = speedSegments.sorted { $0.startSeconds < $1.startSeconds }
    }

    static func singleClip(
      mediaURL: URL,
      sourceStartSeconds: Double = 0,
      sourceEndSeconds: Double? = nil,
      assetDurationSeconds: Double? = nil
    ) -> TimelineModel {
      let sourceStart = max(0, sourceStartSeconds)
      let sourceEnd = max(sourceStart, sourceEndSeconds ?? assetDurationSeconds ?? 0)
      let duration = max(0, sourceEnd - sourceStart)
      return TimelineModel(clips: [
        Clip(
          sourceURL: mediaURL,
          sourceStartSeconds: sourceStart,
          timelineStartSeconds: 0,
          durationSeconds: duration
        ),
      ])
    }
  }

  struct ZoomSegment: Codable, Equatable, Identifiable {
    enum Mode: String, Codable, CaseIterable {
      case auto
      case manual
      case instant
    }

    var id: UUID
    var startSeconds: Double
    var inEndSeconds: Double
    var outStartSeconds: Double
    var endSeconds: Double
    var mode: Mode
    var instantAnimation: Bool
    var scale: Double
    var anchorX: Double
    var anchorY: Double
    var targetX: Double
    var targetY: Double
    var targetWidth: Double
    var targetHeight: Double
    /// Auto zoom segments should resolve against recorded click/input metadata when possible.
    var followsClick: Bool

    enum CodingKeys: String, CodingKey {
      case id
      case startSeconds
      case inEndSeconds
      case outStartSeconds
      case endSeconds
      case mode
      case instantAnimation
      case scale
      case anchorX
      case anchorY
      case targetX
      case targetY
      case targetWidth
      case targetHeight
      case followsClick
    }

    init(
      id: UUID = UUID(),
      startSeconds: Double,
      inEndSeconds: Double? = nil,
      outStartSeconds: Double? = nil,
      endSeconds: Double,
      mode: Mode = .manual,
      instantAnimation: Bool = false,
      scale: Double,
      anchorX: Double,
      anchorY: Double,
      targetX: Double? = nil,
      targetY: Double? = nil,
      targetWidth: Double? = nil,
      targetHeight: Double? = nil,
      followsClick: Bool = false
    ) {
      self.id = id
      self.startSeconds = max(0, startSeconds)
      self.endSeconds = max(0, endSeconds)
      self.mode = mode
      self.instantAnimation = instantAnimation || mode == .instant
      self.scale = RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(scale)
      self.anchorX = max(0, min(1, anchorX))
      self.anchorY = max(0, min(1, anchorY))
      let legacyRegion = Self.targetRegion(scale: self.scale, anchorX: self.anchorX, anchorY: self.anchorY)
      self.targetX = targetX ?? legacyRegion.x
      self.targetY = targetY ?? legacyRegion.y
      self.targetWidth = targetWidth ?? legacyRegion.width
      self.targetHeight = targetHeight ?? legacyRegion.height
      self.followsClick = followsClick
      if self.endSeconds < self.startSeconds {
        swap(&self.startSeconds, &self.endSeconds)
      }
      let span = max(0, self.endSeconds - self.startSeconds)
      if self.instantAnimation {
        self.inEndSeconds = max(self.startSeconds, min(self.endSeconds, inEndSeconds ?? self.startSeconds))
      } else {
        self.inEndSeconds = max(self.startSeconds, min(self.endSeconds, inEndSeconds ?? self.startSeconds + span * 0.22))
      }
      self.outStartSeconds = max(self.inEndSeconds, min(self.endSeconds, outStartSeconds ?? self.endSeconds - span * 0.22))
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
      let start = try c.decode(Double.self, forKey: .startSeconds)
      let end = try c.decode(Double.self, forKey: .endSeconds)
      let mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .manual
      let instant = try c.decodeIfPresent(Bool.self, forKey: .instantAnimation) ?? false
      let scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.35
      let anchorX = try c.decodeIfPresent(Double.self, forKey: .anchorX) ?? 0.5
      let anchorY = try c.decodeIfPresent(Double.self, forKey: .anchorY) ?? 0.5
      self.init(
        id: id,
        startSeconds: start,
        inEndSeconds: try c.decodeIfPresent(Double.self, forKey: .inEndSeconds),
        outStartSeconds: try c.decodeIfPresent(Double.self, forKey: .outStartSeconds),
        endSeconds: end,
        mode: mode,
        instantAnimation: instant,
        scale: scale,
        anchorX: anchorX,
        anchorY: anchorY,
        targetX: try c.decodeIfPresent(Double.self, forKey: .targetX),
        targetY: try c.decodeIfPresent(Double.self, forKey: .targetY),
        targetWidth: try c.decodeIfPresent(Double.self, forKey: .targetWidth),
        targetHeight: try c.decodeIfPresent(Double.self, forKey: .targetHeight),
        followsClick: try c.decodeIfPresent(Bool.self, forKey: .followsClick) ?? false
      )
    }

    var asZoomKeyframe: ZoomKeyframe {
      ZoomKeyframe(
        id: id,
        startSeconds: startSeconds,
        inEndSeconds: inEndSeconds,
        outStartSeconds: outStartSeconds,
        endSeconds: endSeconds,
        scale: scale,
        anchorX: anchorX,
        anchorY: anchorY,
        targetX: targetX,
        targetY: targetY,
        targetWidth: targetWidth,
        targetHeight: targetHeight
      )
    }

    static func fromKeyframe(_ keyframe: ZoomKeyframe) -> ZoomSegment {
      ZoomSegment(
        id: keyframe.id,
        startSeconds: keyframe.startSeconds,
        inEndSeconds: keyframe.inEndSeconds,
        outStartSeconds: keyframe.outStartSeconds,
        endSeconds: keyframe.endSeconds,
        mode: .manual,
        instantAnimation: false,
        scale: keyframe.scale,
        anchorX: keyframe.anchorX,
        anchorY: keyframe.anchorY,
        targetX: keyframe.targetX,
        targetY: keyframe.targetY,
        targetWidth: keyframe.targetWidth,
        targetHeight: keyframe.targetHeight
      )
    }

    static let minTargetRegionSize: Double = 0.08
    static let minZoomLevel: Double = 1.0
    static let maxZoomLevel: Double = 8.0

    static func targetRegion(scale: Double, anchorX: Double, anchorY: Double) -> (x: Double, y: Double, width: Double, height: Double) {
      let clampedScale = RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(scale)
      let size = max(minTargetRegionSize, min(1, 1 / max(1, clampedScale)))
      let x = max(0, min(1 - size, anchorX - size / 2))
      let y = max(0, min(1 - size, anchorY - size / 2))
      return (x, y, size, size)
    }

    var targetCenter: (x: Double, y: Double) {
      let rect = sanitizedTargetRegion()
      return (rect.x + rect.width / 2, rect.y + rect.height / 2)
    }

    var targetZoomLevel: Double {
      let rect = sanitizedTargetRegion()
      let zoom = min(1 / max(rect.width, Self.minTargetRegionSize), 1 / max(rect.height, Self.minTargetRegionSize))
      return Self.clampZoomLevel(zoom)
    }

    mutating func setTargetCenter(x: Double, y: Double) {
      setTargetRegion(centerX: x, centerY: y, zoomLevel: targetZoomLevel)
    }

    mutating func setTargetZoomLevel(_ zoomLevel: Double) {
      let center = targetCenter
      setTargetRegion(centerX: center.x, centerY: center.y, zoomLevel: zoomLevel)
    }

    mutating func setTargetRegion(centerX: Double, centerY: Double, zoomLevel: Double) {
      let zoom = Self.clampZoomLevel(zoomLevel)
      let size = max(Self.minTargetRegionSize, min(1, 1 / zoom))
      targetWidth = size
      targetHeight = size
      targetX = max(0, min(1 - size, centerX - size / 2))
      targetY = max(0, min(1 - size, centerY - size / 2))
      syncLegacyZoomFromTargetRegion()
    }

    mutating func syncLegacyZoomFromTargetRegion() {
      let rect = sanitizedTargetRegion()
      targetX = rect.x
      targetY = rect.y
      targetWidth = rect.width
      targetHeight = rect.height
      anchorX = rect.x + rect.width / 2
      anchorY = rect.y + rect.height / 2
      scale = RecordingProject.TimelineKeyframeSanitize.clampedZoomScale(
        min(1 / max(rect.width, Self.minTargetRegionSize), 1 / max(rect.height, Self.minTargetRegionSize))
      )
    }

    func sanitizedTargetRegion() -> (x: Double, y: Double, width: Double, height: Double) {
      let minSize = max(Self.minTargetRegionSize, 1 / Self.maxZoomLevel)
      let size = max(minSize, min(1, min(targetWidth, targetHeight)))
      return (
        x: max(0, min(1 - size, targetX)),
        y: max(0, min(1 - size, targetY)),
        width: size,
        height: size
      )
    }

    private static func clampZoomLevel(_ value: Double) -> Double {
      max(minZoomLevel, min(maxZoomLevel, value))
    }
  }

  struct AutoZoomMotionFrame: Codable, Equatable {
    var timeSeconds: Double
    var anchorX: Double
    var anchorY: Double
    var scale: Double

    init(timeSeconds: Double, anchorX: Double, anchorY: Double, scale: Double) {
      self.timeSeconds = max(0, timeSeconds)
      self.anchorX = max(0, min(1, anchorX))
      self.anchorY = max(0, min(1, anchorY))
      self.scale = TimelineKeyframeSanitize.clampedZoomScale(scale)
    }
  }

  struct AutoZoomAnalysis: Codable, Equatable {
    static let currentAlgorithmVersion = 1

    var algorithmVersion: Int
    var sourceSignature: String
    var assetDurationSeconds: Double
    var focusRegions: [FocusRegion]
    var motionFrames: [AutoZoomMotionFrame]
    var editableSegments: [ZoomSegment]

    init(
      algorithmVersion: Int = currentAlgorithmVersion,
      sourceSignature: String,
      assetDurationSeconds: Double,
      focusRegions: [FocusRegion],
      motionFrames: [AutoZoomMotionFrame],
      editableSegments: [ZoomSegment]
    ) {
      self.algorithmVersion = algorithmVersion
      self.sourceSignature = sourceSignature
      self.assetDurationSeconds = max(0, assetDurationSeconds)
      self.focusRegions = focusRegions
      self.motionFrames = motionFrames
        .filter { $0.timeSeconds >= 0 }
        .sorted { $0.timeSeconds < $1.timeSeconds }
      self.editableSegments = RecordingProject.sanitizedZoomSegments(
        editableSegments,
        durationSeconds: assetDurationSeconds
      )
    }

    func matches(sourceSignature: String, assetDurationSeconds: Double) -> Bool {
      algorithmVersion == Self.currentAlgorithmVersion
        && self.sourceSignature == sourceSignature
        && abs(self.assetDurationSeconds - assetDurationSeconds) < 0.05
        && !motionFrames.isEmpty
    }
  }

  struct InputEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
      case mouseDown
      case mouseUp
      case keyDown
      case keyUp
      case flagsChanged
    }

    var id: UUID
    var timeSeconds: Double
    var kind: Kind
    var x: Double?
    var y: Double?
    var keyCode: UInt16?
    var characters: String?
    var modifierFlagsRaw: UInt64

    init(
      id: UUID = UUID(),
      timeSeconds: Double,
      kind: Kind,
      x: Double? = nil,
      y: Double? = nil,
      keyCode: UInt16? = nil,
      characters: String? = nil,
      modifierFlagsRaw: UInt64 = 0
    ) {
      self.id = id
      self.timeSeconds = max(0, timeSeconds)
      self.kind = kind
      self.x = x.map { max(0, min(1, $0)) }
      self.y = y.map { max(0, min(1, $0)) }
      self.keyCode = keyCode
      self.characters = characters
      self.modifierFlagsRaw = modifierFlagsRaw
    }

    var shortcutDisplayText: String? {
      guard kind == .keyDown else { return nil }
      let key = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard let key, !key.isEmpty else { return nil }
      var parts: [String] = []
      if modifierFlagsRaw & UInt64(NSEvent.ModifierFlags.command.rawValue) != 0 { parts.append("⌘") }
      if modifierFlagsRaw & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0 { parts.append("⌥") }
      if modifierFlagsRaw & UInt64(NSEvent.ModifierFlags.control.rawValue) != 0 { parts.append("⌃") }
      if modifierFlagsRaw & UInt64(NSEvent.ModifierFlags.shift.rawValue) != 0 { parts.append("⇧") }
      parts.append(key)
      return parts.joined()
    }
  }

  struct AudioTrackSettings: Codable, Equatable {
    enum Role: String, Codable {
      case microphone
      case system
      case backgroundMusic
    }

    struct Track: Codable, Equatable {
      var isEnabled: Bool
      var volume: Double

      init(isEnabled: Bool = false, volume: Double = 1) {
        self.isEnabled = isEnabled
        self.volume = max(0, min(2, volume))
      }
    }

    var microphone: Track
    var system: Track
    var backgroundMusic: Track
    var backgroundMusicURL: URL?
    /// Optional metadata for the audio track order written into the recorded movie. Older projects omit this and use exporter fallback inference.
    var recordedTrackRoles: [Role]?

    init(
      microphone: Track = Track(),
      system: Track = Track(),
      backgroundMusic: Track = Track(),
      backgroundMusicURL: URL? = nil,
      recordedTrackRoles: [Role]? = nil
    ) {
      self.microphone = microphone
      self.system = system
      self.backgroundMusic = backgroundMusic
      self.backgroundMusicURL = backgroundMusicURL
      self.recordedTrackRoles = Self.sanitizedRecordedTrackRoles(recordedTrackRoles)
    }

    func volumeForCompositionTrack(index: Int, totalCount: Int) -> Double {
      if let role = explicitRoleForCompositionTrack(index: index, totalCount: totalCount) {
        return volume(for: role)
      }
      return inferredVolumeForCompositionTrack(index: index, totalCount: totalCount)
    }

    private static func sanitizedRecordedTrackRoles(_ roles: [Role]?) -> [Role]? {
      guard let roles else { return nil }
      var seen = Set<Role>()
      let sanitized = roles.compactMap { role -> Role? in
        guard role != .backgroundMusic, !seen.contains(role) else { return nil }
        seen.insert(role)
        return role
      }
      return sanitized.isEmpty ? nil : sanitized
    }

    private func explicitRoleForCompositionTrack(index: Int, totalCount: Int) -> Role? {
      guard index >= 0, index < totalCount else { return nil }
      var roles = recordedTrackRoles ?? []
      if backgroundMusic.isEnabled && backgroundMusicURL != nil {
        roles.append(.backgroundMusic)
      }
      guard roles.count == totalCount else { return nil }
      return roles[index]
    }

    func compositionRole(forTrackIndex index: Int, totalCount: Int) -> Role? {
      explicitRoleForCompositionTrack(index: index, totalCount: totalCount)
    }

    func effectiveVolume(for role: Role) -> Double {
      volume(for: role)
    }

    private func volume(for role: Role) -> Double {
      switch role {
      case .microphone:
        return microphone.isEnabled ? microphone.volume : 0
      case .system:
        return system.isEnabled ? system.volume : 0
      case .backgroundMusic:
        return backgroundMusic.isEnabled ? backgroundMusic.volume : 0
      }
    }

    private func inferredVolumeForCompositionTrack(index: Int, totalCount: Int) -> Double {
      let hasBackgroundMusic = backgroundMusic.isEnabled && backgroundMusicURL != nil

      if totalCount >= 3, hasBackgroundMusic {
        if index == 0 {
          return microphone.isEnabled ? microphone.volume : 0
        }
        if index == 1 {
          return system.isEnabled ? system.volume : 0
        }
        return backgroundMusic.volume
      }

      if totalCount == 2, hasBackgroundMusic {
        if index == 1 {
          return backgroundMusic.volume
        }
        if microphone.isEnabled {
          return microphone.volume
        }
        if system.isEnabled {
          return system.volume
        }
        return 1
      }

      if totalCount == 1, hasBackgroundMusic, !microphone.isEnabled, !system.isEnabled {
        return backgroundMusic.volume
      }

      if totalCount >= 2 {
        if index == 0 {
          return microphone.isEnabled ? microphone.volume : 0
        }
        if index == 1 {
          return system.isEnabled ? system.volume : 0
        }
        return 1
      }

      if microphone.isEnabled {
        return microphone.volume
      }
      if system.isEnabled {
        return system.volume
      }
      return 0
    }
  }

  enum TimelineMediaEditing {
    static let minAudioSpanSeconds = 0.1
    static let minCameraSpanSeconds = 0.1
  }

  struct AudioTimelineSegment: Codable, Equatable, Identifiable {
    var id: UUID
    var role: AudioTrackSettings.Role
    var startSeconds: Double
    var endSeconds: Double

    init(
      id: UUID = UUID(),
      role: AudioTrackSettings.Role,
      startSeconds: Double,
      endSeconds: Double
    ) {
      self.id = id
      self.role = role
      self.startSeconds = max(0, startSeconds)
      self.endSeconds = max(0, endSeconds)
      if self.endSeconds < self.startSeconds {
        swap(&self.startSeconds, &self.endSeconds)
      }
    }
  }

  struct CaptionTrack: Codable, Equatable {
    struct Segment: Codable, Equatable, Identifiable {
      var id: UUID
      var startSeconds: Double
      var endSeconds: Double
      var text: String

      init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double, text: String) {
        self.id = id
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = max(0, endSeconds)
        self.text = String(text.prefix(2_048))
        if self.endSeconds < self.startSeconds {
          swap(&self.startSeconds, &self.endSeconds)
        }
      }
    }

    struct Style: Codable, Equatable {
      var fontPointSize: Double
      var bottomInsetN: Double
      var backgroundOpacity: Double

      init(fontPointSize: Double = 30, bottomInsetN: Double = 0.08, backgroundOpacity: Double = 0.35) {
        self.fontPointSize = max(10, min(120, fontPointSize))
        self.bottomInsetN = max(0, min(0.35, bottomInsetN))
        self.backgroundOpacity = max(0, min(1, backgroundOpacity))
      }
    }

    var isEnabled: Bool
    var transcript: String
    var languageIdentifier: String
    var segments: [Segment]
    var style: Style

    init(
      isEnabled: Bool = false,
      transcript: String = "",
      languageIdentifier: String = "ja-JP",
      segments: [Segment] = [],
      style: Style = Style()
    ) {
      self.isEnabled = isEnabled
      self.transcript = String(transcript.prefix(20_000))
      self.languageIdentifier = languageIdentifier
      self.segments = segments.sorted { $0.startSeconds < $1.startSeconds }
      self.style = style
    }

    static func fromTextOverlays(_ overlays: [TextOverlayAnnotation]) -> CaptionTrack {
      CaptionTrack(
        isEnabled: !overlays.isEmpty,
        transcript: overlays.map(\.text).joined(separator: "\n"),
        segments: overlays.map {
          Segment(id: $0.id, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, text: $0.text)
        }
      )
    }

    func asTextOverlays() -> [TextOverlayAnnotation] {
      guard isEnabled else { return [] }
      let heightN = 0.12
      let y = max(0, min(1 - heightN, 1 - style.bottomInsetN - heightN))
      return segments.map {
        TextOverlayAnnotation(
          id: $0.id,
          startSeconds: $0.startSeconds,
          endSeconds: $0.endSeconds,
          text: $0.text,
          originXN: 0.08,
          originYN: y,
          widthN: 0.84,
          heightN: heightN,
          fontPointSize: style.fontPointSize
        )
      }
    }
  }

  struct VisualMask: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
      case blur
      case highlight
    }

    var id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var kind: Kind
    var originXN: Double
    var originYN: Double
    var widthN: Double
    var heightN: Double
    var opacity: Double

    init(
      id: UUID = UUID(),
      startSeconds: Double,
      endSeconds: Double,
      kind: Kind,
      originXN: Double = 0.35,
      originYN: Double = 0.35,
      widthN: Double = 0.3,
      heightN: Double = 0.18,
      opacity: Double = 0.65
    ) {
      self.id = id
      self.startSeconds = max(0, startSeconds)
      self.endSeconds = max(0, endSeconds)
      self.kind = kind
      self.originXN = max(0, min(1, originXN))
      self.originYN = max(0, min(1, originYN))
      self.widthN = max(0.02, min(1 - self.originXN, widthN))
      self.heightN = max(0.02, min(1 - self.originYN, heightN))
      self.opacity = max(0, min(1, opacity))
      if self.endSeconds < self.startSeconds {
        swap(&self.startSeconds, &self.endSeconds)
      }
    }
  }

  struct CameraLayoutSegment: Codable, Equatable, Identifiable {
    enum Layout: String, Codable, CaseIterable {
      case hidden
      case pip
      case fullscreen
    }

    var id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var layout: Layout
    var originXN: Double
    var originYN: Double
    var widthN: Double
    var heightN: Double
    var cornerRadiusPts: Double
    var isMirrored: Bool
    var shrinkDuringZoom: Bool

    init(
      id: UUID = UUID(),
      startSeconds: Double,
      endSeconds: Double,
      layout: Layout = .pip,
      originXN: Double = CameraPiPDefaults.bottomTrailingOrigin.originXN,
      originYN: Double = CameraPiPDefaults.bottomTrailingOrigin.originYN,
      widthN: Double = CameraPiPDefaults.widthN,
      heightN: Double = CameraPiPDefaults.heightN,
      cornerRadiusPts: Double = CameraPiPDefaults.cornerRadiusPts,
      isMirrored: Bool = false,
      shrinkDuringZoom: Bool = false
    ) {
      self.id = id
      self.startSeconds = max(0, startSeconds)
      self.endSeconds = max(0, endSeconds)
      self.layout = layout
      self.originXN = max(0, min(1, originXN))
      self.originYN = max(0, min(1, originYN))
      self.widthN = max(0.05, min(1 - self.originXN, widthN))
      self.heightN = max(0.05, min(1 - self.originYN, heightN))
      self.cornerRadiusPts = max(0, min(160, cornerRadiusPts))
      self.isMirrored = isMirrored
      self.shrinkDuringZoom = shrinkDuringZoom
      if self.endSeconds < self.startSeconds {
        swap(&self.startSeconds, &self.endSeconds)
      }
    }

    static func defaultPIP(
      durationSeconds: Double,
      videoWidth: Double,
      videoHeight: Double
    ) -> CameraLayoutSegment {
      let geometry = CameraPiPDefaults.bottomTrailingSquarePiP(
        videoWidth: videoWidth,
        videoHeight: videoHeight
      )
      return CameraLayoutSegment(
        startSeconds: 0,
        endSeconds: max(0.1, durationSeconds),
        layout: .pip,
        originXN: geometry.originXN,
        originYN: geometry.originYN,
        widthN: geometry.widthN,
        heightN: geometry.heightN,
        cornerRadiusPts: CameraPiPDefaults.cornerRadiusPts
      )
    }
  }

  struct CursorVisualSettings: Codable, Equatable {
    enum PointerStyle: String, Codable, CaseIterable, Identifiable {
      case spotlight
      case arrow
      case arrowWithRing
      case dot

      var id: String { rawValue }

      var title: String {
        switch self {
        case .spotlight: return "スポットライト"
        case .arrow: return "矢印"
        case .arrowWithRing: return "矢印 + リング"
        case .dot: return "ドット"
        }
      }
    }

    var isVisible: Bool
    var pointerStyle: PointerStyle
    var sizeScale: Double
    var hideWhenIdle: Bool
    var showClickEffects: Bool
    var showKeyboardShortcuts: Bool

    init(
      isVisible: Bool = true,
      pointerStyle: PointerStyle = .arrow,
      sizeScale: Double = 1,
      hideWhenIdle: Bool = false,
      showClickEffects: Bool = true,
      showKeyboardShortcuts: Bool = true
    ) {
      self.isVisible = isVisible
      self.pointerStyle = pointerStyle
      self.sizeScale = max(0.5, min(3, sizeScale))
      self.hideWhenIdle = hideWhenIdle
      self.showClickEffects = showClickEffects
      self.showKeyboardShortcuts = showKeyboardShortcuts
    }

    enum CodingKeys: String, CodingKey {
      case isVisible
      case pointerStyle
      case sizeScale
      case hideWhenIdle
      case showClickEffects
      case showKeyboardShortcuts
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        isVisible: try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
        pointerStyle: try c.decodeIfPresent(PointerStyle.self, forKey: .pointerStyle) ?? .arrow,
        sizeScale: try c.decodeIfPresent(Double.self, forKey: .sizeScale) ?? 1,
        hideWhenIdle: try c.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? false,
        showClickEffects: try c.decodeIfPresent(Bool.self, forKey: .showClickEffects) ?? true,
        showKeyboardShortcuts: try c.decodeIfPresent(Bool.self, forKey: .showKeyboardShortcuts) ?? true
      )
    }
  }

  enum ExportPresetID: String, Codable, CaseIterable, Identifiable {
    case p1080p60
    case p1080p60Hevc
    case p1080p30
    case p1080p30Hevc
    case p720p30
    case p720p30Hevc
    case matchSource60
    case matchSource60Hevc

    var id: String { rawValue }
  }

  enum StylePresetID: String, Codable, CaseIterable, Identifiable {
    case none
    case cursorFocus
    case softZoom

    var id: String { rawValue }

    var title: String {
      switch self {
      case .none: "なし"
      case .cursorFocus: "カーソルフォーカス"
      case .softZoom: "ソフトズーム"
      }
    }
  }

  struct StyleSettings: Codable, Equatable {
    var introFadeSeconds: Double
    var outroFadeSeconds: Double
    var softZoomScale: Double

    private enum CodingKeys: String, CodingKey {
      case introFadeSeconds
      case outroFadeSeconds
      case softZoomScale
    }

    init(introFadeSeconds: Double = 0, outroFadeSeconds: Double = 0, softZoomScale: Double = RecordingProject.StyleSettingsDefaults.softZoomScale) {
      self.introFadeSeconds = RecordingProject.StyleSettingsDefaults.clampedIntroFadeSeconds(introFadeSeconds)
      self.outroFadeSeconds = RecordingProject.StyleSettingsDefaults.clampedOutroFadeSeconds(outroFadeSeconds)
      self.softZoomScale = RecordingProject.StyleSettingsDefaults.clampedSoftZoomScale(softZoomScale)
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let intro = try c.decodeIfPresent(Double.self, forKey: .introFadeSeconds) ?? 0
      let out = try c.decodeIfPresent(Double.self, forKey: .outroFadeSeconds) ?? 0
      let zoom = try c.decodeIfPresent(Double.self, forKey: .softZoomScale) ?? RecordingProject.StyleSettingsDefaults.softZoomScale
      self.init(introFadeSeconds: intro, outroFadeSeconds: out, softZoomScale: zoom)
    }
  }

  enum StyleSettingsDefaults {
    static let introFadeMaxSeconds: Double = 2
    static let outroFadeMaxSeconds: Double = 2
    static let softZoomScaleMin: Double = 1.0
    static let softZoomScaleMax: Double = 1.25
    static let softZoomScale: Double = 1.08

    static func clampedIntroFadeSeconds(_ v: Double) -> Double {
      max(0, min(introFadeMaxSeconds, v))
    }

    static func clampedOutroFadeSeconds(_ v: Double) -> Double {
      max(0, min(outroFadeMaxSeconds, v))
    }

    static func clampedSoftZoomScale(_ v: Double) -> Double {
      max(softZoomScaleMin, min(softZoomScaleMax, v))
    }
  }

  struct CursorHighlightRegion: Codable, Equatable, Identifiable {
    var id: UUID
    var startSeconds: Double
    var endSeconds: Double

    init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double) {
      self.id = id
      self.startSeconds = startSeconds
      self.endSeconds = endSeconds
    }
  }

  /// Timeline text titles (offline / manual captions). Normalized rectangle in export frame (origin top‑left).
  struct TextOverlayAnnotation: Codable, Equatable, Identifiable {
    var id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var text: String
    var originXN: Double
    var originYN: Double
    var widthN: Double
    var heightN: Double
    /// Font point size relative to export height (typically 18–96).
    var fontPointSize: Double

    init(
      id: UUID = UUID(),
      startSeconds: Double,
      endSeconds: Double,
      text: String,
      originXN: Double = 0.04,
      originYN: Double = 0.78,
      widthN: Double = 0.92,
      heightN: Double = 0.12,
      fontPointSize: Double = TextOverlaySanitizeDefaults.defaultFontPts
    ) {
      self.id = id
      self.startSeconds = startSeconds
      self.endSeconds = endSeconds
      self.text = text
      self.originXN = originXN
      self.originYN = originYN
      self.widthN = widthN
      self.heightN = heightN
      self.fontPointSize = fontPointSize
    }
  }

  enum TextOverlaySanitizeDefaults {
    static let defaultFontPts: Double = 28

    static func sanitized(_ overlays: [TextOverlayAnnotation], durationSeconds: Double) -> [TextOverlayAnnotation] {
      let d = max(0, durationSeconds)
      return overlays
        .map { o in
          var o = o
          o.startSeconds = max(0, min(d, o.startSeconds))
          o.endSeconds = max(0, min(d, o.endSeconds))
          if o.endSeconds < o.startSeconds {
            swap(&o.startSeconds, &o.endSeconds)
          }
          if o.endSeconds - o.startSeconds < 0.05 {
            o.endSeconds = min(d, o.startSeconds + 0.05)
          }
          o.originXN = max(0, min(1, o.originXN))
          o.originYN = max(0, min(1, o.originYN))
          o.widthN = max(0.02, min(1 - o.originXN, o.widthN))
          o.heightN = max(0.02, min(1 - o.originYN, o.heightN))
          o.fontPointSize = max(10, min(120, o.fontPointSize))
          let maxLen = 2_048
          if o.text.count > maxLen {
            o.text = String(o.text.prefix(maxLen))
          }
          return o
        }
        .sorted { $0.startSeconds < $1.startSeconds }
    }
  }

  struct ChapterMarker: Codable, Equatable, Identifiable {
    var id: UUID
    var timeSeconds: Double
    var title: String

    init(id: UUID = UUID(), timeSeconds: Double, title: String) {
      self.id = id
      self.timeSeconds = timeSeconds
      self.title = title
    }
  }

  /// Manual or heuristic click emphasis points on the timeline (see export cursor ring pulses).
  struct CursorClickCue: Codable, Equatable, Identifiable {
    var id: UUID
    var timeSeconds: Double

    init(id: UUID = UUID(), timeSeconds: Double) {
      self.id = id
      self.timeSeconds = timeSeconds
    }
  }

  /// Optional face-cam / PiP reel recorded alongside screen (timeline‑aligned from t=0).
  struct SecondaryRecordingAttachment: Codable, Equatable {
    var mediaURL: URL
    /// Normalized rect (top‑left origin) in output frame.
    var originXN: Double
    var originYN: Double
    var widthN: Double
    var heightN: Double
    var cornerRadiusPts: Double

    static func defaultedBottomTrailingPiP(
      mediaURL: URL,
      videoWidth: Double,
      videoHeight: Double
    ) -> SecondaryRecordingAttachment {
      let geometry = CameraPiPDefaults.bottomTrailingSquarePiP(
        videoWidth: videoWidth,
        videoHeight: videoHeight
      )
      return SecondaryRecordingAttachment(
        mediaURL: mediaURL,
        originXN: geometry.originXN,
        originYN: geometry.originYN,
        widthN: geometry.widthN,
        heightN: geometry.heightN,
        cornerRadiusPts: CameraPiPDefaults.cornerRadiusPts
      )
    }

    func clampedForExport() -> SecondaryRecordingAttachment {
      var s = self
      s.originXN = max(0, min(1, originXN))
      s.originYN = max(0, min(1, originYN))
      s.widthN = max(0.05, min(1 - originXN, widthN))
      s.heightN = max(0.05, min(1 - originYN, heightN))
      s.cornerRadiusPts = max(0, min(160, cornerRadiusPts))
      return s
    }
  }

  /// Composition-only staging (canvas background, clipped/signed card shadow, optional device-outline vector).
  struct ExportVisualSettings: Codable, Equatable {
    enum StageStyle: String, Codable, CaseIterable {
      case none
      case roundedCard
    }

    enum BackgroundKind: String, Codable, CaseIterable {
      case solid
      case linearGradientVertical
    }

    /// How a linear gradient background is presented in preview/export.
    enum BackgroundGradientStyle: String, Codable, CaseIterable {
      case vertical
      case wallpaper
    }

    enum DeviceFramePreset: String, Codable, CaseIterable {
      case none
      case laptopOutline
    }

    var stageStyle: StageStyle
    var backgroundKind: BackgroundKind
    var backgroundGradientStyle: BackgroundGradientStyle
    /// Six-digit `#RRGGBB` uppercase or lowercase prefix `#`.
    var backgroundColorHex: String
    var gradientEndColorHex: String
    /// Visual blur for generated / image-like backgrounds. Linear export backgrounds remain deterministic.
    var backgroundBlur: Double
    /// Outer stage padding between the background canvas and the video card.
    var backgroundPadding: Double
    /// Corner radius for the video card.
    var contentCornerRadius: Double
    /// Inner inset between the video card edge and the raw recording.
    var contentInset: Double
    var dropShadowOpacity: Double
    var shadowRadius: Double
    var shadowYOffset: Double
    /// When capturing a whole display (`source.kind == .display`), staged framing is gated by this toggle.
    var enabledForDisplayCapture: Bool
    var deviceFramePreset: DeviceFramePreset

    enum CodingKeys: String, CodingKey {
      case stageStyle
      case backgroundKind
      case backgroundGradientStyle
      case backgroundColorHex
      case gradientEndColorHex
      case backgroundBlur
      case backgroundPadding
      case contentCornerRadius
      case contentInset
      case dropShadowOpacity
      case shadowRadius
      case shadowYOffset
      case enabledForDisplayCapture
      case deviceFramePreset
    }

    init(
      stageStyle: StageStyle,
      backgroundKind: BackgroundKind,
      backgroundGradientStyle: BackgroundGradientStyle = .vertical,
      backgroundColorHex: String,
      gradientEndColorHex: String,
      backgroundBlur: Double = ExportVisualSettingsDefaults.defaultBackgroundBlurPts,
      backgroundPadding: Double = ExportVisualSettingsDefaults.defaultBackgroundPaddingPts,
      contentCornerRadius: Double,
      contentInset: Double,
      dropShadowOpacity: Double,
      shadowRadius: Double,
      shadowYOffset: Double,
      enabledForDisplayCapture: Bool,
      deviceFramePreset: DeviceFramePreset = .none
    ) {
      self.stageStyle = stageStyle
      self.backgroundKind = backgroundKind
      self.backgroundGradientStyle = backgroundGradientStyle
      self.backgroundColorHex = ExportVisualSettingsDefaults.validatedHexOrDefault(backgroundColorHex, fallback: ExportVisualSettingsDefaults.stageBackgroundFallbackHex)
      self.gradientEndColorHex = ExportVisualSettingsDefaults.validatedHexOrDefault(gradientEndColorHex, fallback: ExportVisualSettingsDefaults.stageGradientEndFallbackHex)
      self.backgroundBlur = ExportVisualSettingsDefaults.clampedBackgroundBlurPts(backgroundBlur)
      self.backgroundPadding = ExportVisualSettingsDefaults.clampedBackgroundPaddingPts(backgroundPadding)
      self.contentCornerRadius = ExportVisualSettingsDefaults.clampedCornerRadiusPts(contentCornerRadius)
      self.contentInset = ExportVisualSettingsDefaults.clampedContentInsetPts(contentInset)
      self.dropShadowOpacity = ExportVisualSettingsDefaults.clampedShadowOpacity(dropShadowOpacity)
      self.shadowRadius = ExportVisualSettingsDefaults.clampedShadowRadiusPts(shadowRadius)
      self.shadowYOffset = ExportVisualSettingsDefaults.clampedShadowYOffsetPts(shadowYOffset)
      self.enabledForDisplayCapture = enabledForDisplayCapture
      self.deviceFramePreset = deviceFramePreset
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let bg = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? ExportVisualSettingsDefaults.stageBackgroundFallbackHex
      let gd = try c.decodeIfPresent(String.self, forKey: .gradientEndColorHex) ?? ExportVisualSettingsDefaults.stageGradientEndFallbackHex
      let kind = try c.decodeIfPresent(BackgroundKind.self, forKey: .backgroundKind) ?? .solid
      let gradientStyle = try c.decodeIfPresent(BackgroundGradientStyle.self, forKey: .backgroundGradientStyle)
        ?? Self.inferredGradientStyle(kind: kind, startHex: bg, endHex: gd)
      self.init(
        stageStyle: try c.decodeIfPresent(StageStyle.self, forKey: .stageStyle) ?? .roundedCard,
        backgroundKind: kind,
        backgroundGradientStyle: gradientStyle,
        backgroundColorHex: bg,
        gradientEndColorHex: gd,
        backgroundBlur: try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? ExportVisualSettingsDefaults.defaultBackgroundBlurPts,
        backgroundPadding: try c.decodeIfPresent(Double.self, forKey: .backgroundPadding) ?? ExportVisualSettingsDefaults.defaultBackgroundPaddingPts,
        contentCornerRadius: try c.decodeIfPresent(Double.self, forKey: .contentCornerRadius) ?? ExportVisualSettingsDefaults.defaultCornerRadiusPts,
        contentInset: try c.decodeIfPresent(Double.self, forKey: .contentInset) ?? ExportVisualSettingsDefaults.defaultContentInsetPts,
        dropShadowOpacity: try c.decodeIfPresent(Double.self, forKey: .dropShadowOpacity) ?? ExportVisualSettingsDefaults.defaultShadowOpacity,
        shadowRadius: try c.decodeIfPresent(Double.self, forKey: .shadowRadius) ?? ExportVisualSettingsDefaults.defaultShadowRadiusPts,
        shadowYOffset: try c.decodeIfPresent(Double.self, forKey: .shadowYOffset) ?? ExportVisualSettingsDefaults.defaultShadowYOffsetPts,
        enabledForDisplayCapture: try c.decodeIfPresent(Bool.self, forKey: .enabledForDisplayCapture) ?? false,
        deviceFramePreset: try c.decodeIfPresent(DeviceFramePreset.self, forKey: .deviceFramePreset) ?? .none
      )
    }

    static func inferredGradientStyle(
      kind: BackgroundKind,
      startHex: String,
      endHex: String
    ) -> BackgroundGradientStyle {
      guard kind == .linearGradientVertical else { return .vertical }
      let normalizedStart = ExportVisualSettingsDefaults.validatedHexOrDefault(
        startHex,
        fallback: ExportVisualSettingsDefaults.stageBackgroundFallbackHex
      ).uppercased()
      let normalizedEnd = ExportVisualSettingsDefaults.validatedHexOrDefault(
        endHex,
        fallback: ExportVisualSettingsDefaults.stageGradientEndFallbackHex
      ).uppercased()
      if normalizedStart == ExportVisualSettingsDefaults.stageBackgroundFallbackHex.uppercased(),
         normalizedEnd == ExportVisualSettingsDefaults.stageGradientEndFallbackHex.uppercased() {
        return .wallpaper
      }
      return .vertical
    }

    /// Safe defaults keyed by capture kind (window recording gets staged polish by default; full display stays off until toggled).
    static func defaulted(forSourceKind kind: SourceKind) -> ExportVisualSettings {
      switch kind {
      case .display, .area:
        return ExportVisualSettings(
          stageStyle: .roundedCard,
          backgroundKind: .linearGradientVertical,
          backgroundGradientStyle: .wallpaper,
          backgroundColorHex: ExportVisualSettingsDefaults.stageBackgroundFallbackHex,
          gradientEndColorHex: ExportVisualSettingsDefaults.stageGradientEndFallbackHex,
          backgroundBlur: ExportVisualSettingsDefaults.defaultBackgroundBlurPts,
          backgroundPadding: ExportVisualSettingsDefaults.defaultBackgroundPaddingPts,
          contentCornerRadius: ExportVisualSettingsDefaults.defaultCornerRadiusPts,
          contentInset: ExportVisualSettingsDefaults.defaultContentInsetPts,
          dropShadowOpacity: ExportVisualSettingsDefaults.defaultShadowOpacity,
          shadowRadius: ExportVisualSettingsDefaults.defaultShadowRadiusPts,
          shadowYOffset: ExportVisualSettingsDefaults.defaultShadowYOffsetPts,
          enabledForDisplayCapture: true,
          deviceFramePreset: .none
        )
      case .window:
        return ExportVisualSettings(
          stageStyle: .roundedCard,
          backgroundKind: .linearGradientVertical,
          backgroundGradientStyle: .wallpaper,
          backgroundColorHex: ExportVisualSettingsDefaults.stageBackgroundFallbackHex,
          gradientEndColorHex: ExportVisualSettingsDefaults.stageGradientEndFallbackHex,
          backgroundBlur: ExportVisualSettingsDefaults.defaultBackgroundBlurPts,
          backgroundPadding: ExportVisualSettingsDefaults.defaultBackgroundPaddingPts,
          contentCornerRadius: ExportVisualSettingsDefaults.defaultCornerRadiusPts,
          contentInset: ExportVisualSettingsDefaults.defaultContentInsetPts,
          dropShadowOpacity: ExportVisualSettingsDefaults.defaultShadowOpacity,
          shadowRadius: ExportVisualSettingsDefaults.defaultShadowRadiusPts,
          shadowYOffset: ExportVisualSettingsDefaults.defaultShadowYOffsetPts,
          enabledForDisplayCapture: true,
          deviceFramePreset: .none
        )
      }
    }

    enum ExportVisualSettingsDefaults {
      static let backgroundBlurMaxPts: Double = 40
      static let backgroundPaddingMaxPts: Double = 128
      static let contentCornerRadiusMaxPts: Double = 48
      static let contentInsetMaxPts: Double = 64
      static let shadowRadiusMaxPts: Double = 48
      static let shadowYOffsetMaxAbsPts: Double = 36

      static let defaultBackgroundBlurPts: Double = 0
      static let defaultBackgroundPaddingPts: Double = 24
      static let defaultCornerRadiusPts: Double = 18
      static let defaultContentInsetPts: Double = 0
      static let defaultShadowOpacity: Double = 0.42
      static let defaultShadowRadiusPts: Double = 24
      static let defaultShadowYOffsetPts: Double = -8

      /// Soft editorial stage colors used for the first post-recording preview.
      static let stageBackgroundFallbackHex = "#EEF2F3"
      static let stageGradientEndFallbackHex = "#8FCAC4"

      static func clampedCornerRadiusPts(_ v: Double) -> Double {
        max(0, min(contentCornerRadiusMaxPts, v))
      }

      static func clampedBackgroundBlurPts(_ v: Double) -> Double {
        max(0, min(backgroundBlurMaxPts, v))
      }

      static func clampedBackgroundPaddingPts(_ v: Double) -> Double {
        max(0, min(backgroundPaddingMaxPts, v))
      }

      static func clampedContentInsetPts(_ v: Double) -> Double {
        max(0, min(contentInsetMaxPts, v))
      }

      static func clampedShadowOpacity(_ v: Double) -> Double {
        max(0, min(1, v))
      }

      static func clampedShadowRadiusPts(_ v: Double) -> Double {
        max(0, min(shadowRadiusMaxPts, v))
      }

      static func clampedShadowYOffsetPts(_ v: Double) -> Double {
        max(-shadowYOffsetMaxAbsPts, min(shadowYOffsetMaxAbsPts, v))
      }

      static func validatedHexOrDefault(_ raw: String, fallback: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = s.dropFirst()
        guard s.hasPrefix("#"), hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else {
          return fallback
        }
        return "#\(hex.uppercased())"
      }
    }
  }

  var schemaVersion: Int
  var id: UUID
  var createdAt: Date
  var title: String
  var source: Source
  var mediaURL: URL
  var cursorSamples: [CursorSample]
  var exportPreset: ExportPresetID
  var outputAspectRatio: AspectRatioPreset
  var stylePreset: StylePresetID
  var styleSettings: StyleSettings
  var cursorHighlightRegions: [CursorHighlightRegion]
  var exportVisualSettings: ExportVisualSettings
  /// Title cards / labels (exported as Core Animation text when non-empty).
  var textOverlayAnnotations: [TextOverlayAnnotation]
  /// Editorial markers — not burned into exported MP4 by default; persisted for tooling.
  var chapterMarkers: [ChapterMarker]
  /// Click emphasis markers (exported as ring pulses alongside cursor animations).
  var cursorClickCues: [CursorClickCue]
  /// Optional camera / PiP movie aligned with primary screen recording.
  var secondaryRecording: SecondaryRecordingAttachment?
  /// Non-destructive editing model for clip-based workflows.
  var timeline: TimelineModel
  var zoomSegments: [ZoomSegment]
  /// Mouse and keyboard events recorded during capture.
  var inputEvents: [InputEvent]
  var audioTrackSettings: AudioTrackSettings
  var captionTrack: CaptionTrack
  var visualMasks: [VisualMask]
  var cameraLayoutSegments: [CameraLayoutSegment]
  var audioTimelineSegments: [AudioTimelineSegment]
  var cursorVisualSettings: CursorVisualSettings
  var autoZoomAnalysis: AutoZoomAnalysis?

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case createdAt
    case title
    case source
    case mediaURL
    case cursorSamples
    case exportPreset
    case outputAspectRatio
    case stylePreset
    case styleSettings
    case cursorHighlightRegions
    case exportVisualSettings
    case textOverlayAnnotations
    case chapterMarkers
    case cursorClickCues
    case secondaryRecording
    case timeline
    case zoomSegments
    case inputEvents
    case audioTrackSettings
    case captionTrack
    case visualMasks
    case cameraLayoutSegments
    case audioTimelineSegments
    case cursorVisualSettings
    case autoZoomAnalysis
  }

  private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
    }

    init?(intValue: Int) {
      self.stringValue = String(intValue)
      self.intValue = intValue
    }
  }

  init(
    schemaVersion: Int = Schema.currentVersion,
    id: UUID,
    createdAt: Date,
    title: String,
    source: Source,
    mediaURL: URL,
    cursorSamples: [CursorSample],
    exportPreset: ExportPresetID,
    outputAspectRatio: AspectRatioPreset = .sixteenNine,
    stylePreset: StylePresetID,
    styleSettings: StyleSettings = StyleSettings(),
    cursorHighlightRegions: [CursorHighlightRegion] = [],
    exportVisualSettings: ExportVisualSettings? = nil,
    textOverlayAnnotations: [TextOverlayAnnotation] = [],
    chapterMarkers: [ChapterMarker] = [],
    cursorClickCues: [CursorClickCue] = [],
    secondaryRecording: SecondaryRecordingAttachment? = nil,
    timeline: TimelineModel = TimelineModel(),
    zoomSegments: [ZoomSegment] = [],
    inputEvents: [InputEvent] = [],
    audioTrackSettings: AudioTrackSettings = AudioTrackSettings(),
    captionTrack: CaptionTrack? = nil,
    visualMasks: [VisualMask] = [],
    cameraLayoutSegments: [CameraLayoutSegment] = [],
    audioTimelineSegments: [AudioTimelineSegment] = [],
    cursorVisualSettings: CursorVisualSettings = CursorVisualSettings(),
    autoZoomAnalysis: AutoZoomAnalysis? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.createdAt = createdAt
    self.title = title
    self.source = source
    self.mediaURL = mediaURL
    self.cursorSamples = cursorSamples
    self.exportPreset = exportPreset
    self.outputAspectRatio = outputAspectRatio
    self.stylePreset = stylePreset
    self.styleSettings = styleSettings
    self.cursorHighlightRegions = cursorHighlightRegions
    let baseVisual = exportVisualSettings ?? ExportVisualSettings.defaulted(forSourceKind: source.kind)
    self.exportVisualSettings = Self.clampedExportVisual(baseVisual)
    self.textOverlayAnnotations = textOverlayAnnotations
    self.chapterMarkers = chapterMarkers.sorted { $0.timeSeconds < $1.timeSeconds }
    self.cursorClickCues = Self.sortedUniqueClickCues(cursorClickCues)
    self.secondaryRecording = secondaryRecording?.clampedForExport()
    self.timeline = timeline
    self.zoomSegments = Self.sanitizedZoomSegments(zoomSegments, durationSeconds: nil)
    self.inputEvents = Self.sanitizedInputEvents(inputEvents)
    self.audioTrackSettings = audioTrackSettings
    self.captionTrack = captionTrack ?? CaptionTrack.fromTextOverlays(textOverlayAnnotations)
    self.visualMasks = Self.sanitizedVisualMasks(visualMasks, durationSeconds: nil)
    self.cameraLayoutSegments = Self.sanitizedCameraLayoutSegments(cameraLayoutSegments, durationSeconds: nil)
    self.audioTimelineSegments = Self.sanitizedAudioTimelineSegments(
      audioTimelineSegments,
      durationSeconds: nil,
      settings: audioTrackSettings
    )
    self.cursorVisualSettings = cursorVisualSettings
    self.autoZoomAnalysis = autoZoomAnalysis
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try decoder.container(keyedBy: DynamicCodingKey.self)
    for removedKey in ["trim", "zoomKeyframes"] {
      if raw.contains(DynamicCodingKey(stringValue: removedKey)!) {
        throw DecodingError.dataCorruptedError(
          forKey: DynamicCodingKey(stringValue: removedKey)!,
          in: raw,
          debugDescription: "Removed RecordingProject field '\(removedKey)' is not supported by schema \(Schema.currentVersion)."
        )
      }
    }
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == Schema.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: c,
        debugDescription: "Unsupported RecordingProject schema \(schemaVersion). Expected \(Schema.currentVersion)."
      )
    }
    id = try c.decode(UUID.self, forKey: .id)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? "収録"
    source = try c.decode(Source.self, forKey: .source)
    mediaURL = try c.decode(URL.self, forKey: .mediaURL)
    cursorSamples = try c.decodeIfPresent([CursorSample].self, forKey: .cursorSamples) ?? []
    exportPreset = try Self.decodedPresetID(from: c)
    outputAspectRatio = try c.decodeIfPresent(AspectRatioPreset.self, forKey: .outputAspectRatio) ?? .sixteenNine

    stylePreset = try c.decodeIfPresent(StylePresetID.self, forKey: .stylePreset) ?? .none
    styleSettings = try c.decodeIfPresent(StyleSettings.self, forKey: .styleSettings) ?? StyleSettings()
    cursorHighlightRegions = try c.decodeIfPresent([CursorHighlightRegion].self, forKey: .cursorHighlightRegions) ?? []

    textOverlayAnnotations = try c.decodeIfPresent([TextOverlayAnnotation].self, forKey: .textOverlayAnnotations) ?? []
    chapterMarkers = try c.decodeIfPresent([ChapterMarker].self, forKey: .chapterMarkers) ?? []
    cursorClickCues = try c.decodeIfPresent([CursorClickCue].self, forKey: .cursorClickCues) ?? []
    secondaryRecording = try c.decodeIfPresent(SecondaryRecordingAttachment.self, forKey: .secondaryRecording)
    timeline = try c.decode(TimelineModel.self, forKey: .timeline)
    zoomSegments = try c.decode([ZoomSegment].self, forKey: .zoomSegments)
    inputEvents = try c.decodeIfPresent([InputEvent].self, forKey: .inputEvents) ?? []
    audioTrackSettings = try c.decodeIfPresent(AudioTrackSettings.self, forKey: .audioTrackSettings) ?? AudioTrackSettings()
    captionTrack = try c.decodeIfPresent(CaptionTrack.self, forKey: .captionTrack)
      ?? CaptionTrack.fromTextOverlays(textOverlayAnnotations)
    visualMasks = try c.decodeIfPresent([VisualMask].self, forKey: .visualMasks) ?? []
    cameraLayoutSegments = try c.decodeIfPresent([CameraLayoutSegment].self, forKey: .cameraLayoutSegments) ?? []
    audioTimelineSegments = try c.decodeIfPresent([AudioTimelineSegment].self, forKey: .audioTimelineSegments) ?? []
    cursorVisualSettings = try c.decodeIfPresent(CursorVisualSettings.self, forKey: .cursorVisualSettings) ?? CursorVisualSettings()
    autoZoomAnalysis = try c.decodeIfPresent(AutoZoomAnalysis.self, forKey: .autoZoomAnalysis)

    if let visuals = try c.decodeIfPresent(ExportVisualSettings.self, forKey: .exportVisualSettings) {
      exportVisualSettings = Self.clampedExportVisual(visuals)
    } else {
      exportVisualSettings = Self.clampedExportVisual(ExportVisualSettings.defaulted(forSourceKind: source.kind))
    }

    zoomSegments = Self.sanitizedZoomSegments(zoomSegments, durationSeconds: nil)
    inputEvents = Self.sanitizedInputEvents(inputEvents)
    visualMasks = Self.sanitizedVisualMasks(visualMasks, durationSeconds: nil)
    cameraLayoutSegments = Self.sanitizedCameraLayoutSegments(cameraLayoutSegments, durationSeconds: nil)
    audioTimelineSegments = Self.sanitizedAudioTimelineSegments(
      audioTimelineSegments,
      durationSeconds: nil,
      settings: audioTrackSettings
    )
  }

  static func defaultAudioTimelineRoles(settings: AudioTrackSettings) -> [AudioTrackSettings.Role] {
    var roles = settings.recordedTrackRoles?.filter { $0 != .backgroundMusic } ?? []
    if roles.isEmpty {
      if settings.microphone.isEnabled || settings.recordedTrackRoles == nil {
        roles.append(.microphone)
      }
      if settings.system.isEnabled {
        roles.append(.system)
      }
    }
    if roles.isEmpty {
      roles = [.microphone]
    }
    if settings.backgroundMusicURL != nil {
      roles.append(.backgroundMusic)
    }
    var seen = Set<AudioTrackSettings.Role>()
    return roles.compactMap { role in
      guard !seen.contains(role) else { return nil }
      seen.insert(role)
      return role
    }
  }

  static func defaultAudioTimelineSegments(
    durationSeconds: Double,
    settings: AudioTrackSettings
  ) -> [AudioTimelineSegment] {
    let duration = max(TimelineMediaEditing.minAudioSpanSeconds, durationSeconds)
    return defaultAudioTimelineRoles(settings: settings).map { role in
      AudioTimelineSegment(role: role, startSeconds: 0, endSeconds: duration)
    }
  }

  static func sanitizedAudioTimelineSegments(
    _ segments: [AudioTimelineSegment],
    durationSeconds: Double?,
    settings: AudioTrackSettings
  ) -> [AudioTimelineSegment] {
    let duration = durationSeconds.map { max(TimelineMediaEditing.minAudioSpanSeconds, $0) }
    let allowedRoles = Set(defaultAudioTimelineRoles(settings: settings))
    return segments
      .filter { allowedRoles.contains($0.role) }
      .map { segment in
        var s = segment
        if let duration {
          s.startSeconds = max(0, min(duration, s.startSeconds))
          s.endSeconds = max(0, min(duration, s.endSeconds))
        }
        if s.endSeconds < s.startSeconds {
          swap(&s.startSeconds, &s.endSeconds)
        }
        let minSpan = TimelineMediaEditing.minAudioSpanSeconds
        if s.endSeconds - s.startSeconds < minSpan {
          s.endSeconds = s.startSeconds + minSpan
          if let duration {
            s.endSeconds = min(duration, s.endSeconds)
            s.startSeconds = max(0, s.endSeconds - minSpan)
          }
        }
        return AudioTimelineSegment(
          id: s.id,
          role: s.role,
          startSeconds: s.startSeconds,
          endSeconds: s.endSeconds
        )
      }
      .sorted { lhs, rhs in
        if lhs.role.rawValue != rhs.role.rawValue {
          return lhs.role.rawValue < rhs.role.rawValue
        }
        return lhs.startSeconds < rhs.startSeconds
      }
  }

  static func ensureAudioTimelineSegments(
    _ project: inout RecordingProject,
    durationSeconds: Double
  ) {
    if project.audioTimelineSegments.isEmpty {
      project.audioTimelineSegments = defaultAudioTimelineSegments(
        durationSeconds: durationSeconds,
        settings: project.audioTrackSettings
      )
      return
    }
    var segments = sanitizedAudioTimelineSegments(
      project.audioTimelineSegments,
      durationSeconds: durationSeconds,
      settings: project.audioTrackSettings
    )
    segments = extendDefaultStubAudioSegments(segments: segments, durationSeconds: durationSeconds)
    project.audioTimelineSegments = segments
  }

  static func ensureCameraLayoutSegments(
    _ project: inout RecordingProject,
    durationSeconds: Double,
    videoWidth: Double = 1920,
    videoHeight: Double = 1080
  ) {
    guard project.secondaryRecording != nil else {
      if !project.cameraLayoutSegments.isEmpty {
        project.cameraLayoutSegments = []
      }
      return
    }
    if project.cameraLayoutSegments.isEmpty {
      project.cameraLayoutSegments = [
        CameraLayoutSegment.defaultPIP(
          durationSeconds: max(0.1, durationSeconds),
          videoWidth: videoWidth,
          videoHeight: videoHeight
        ),
      ]
      return
    }
    var segments = sanitizedCameraLayoutSegments(
      project.cameraLayoutSegments,
      durationSeconds: durationSeconds
    )
    segments = extendDefaultStubCameraSegments(segments: segments, durationSeconds: durationSeconds)
    project.cameraLayoutSegments = segments
  }

  /// Recording handoff can create 0.1s stub spans before asset duration is known; extend them once real duration loads.
  private static func isDefaultStubSpanEnd(_ endSeconds: Double) -> Bool {
    endSeconds <= TimelineMediaEditing.minCameraSpanSeconds + 0.05
  }

  private static func extendDefaultStubCameraSegments(
    segments: [CameraLayoutSegment],
    durationSeconds: Double
  ) -> [CameraLayoutSegment] {
    guard durationSeconds > TimelineMediaEditing.minCameraSpanSeconds + 0.05,
          segments.count == 1,
          let only = segments.first,
          only.startSeconds <= 0.001,
          isDefaultStubSpanEnd(only.endSeconds)
    else { return segments }
    var extended = only
    extended.endSeconds = durationSeconds
    return [extended]
  }

  private static func extendDefaultStubAudioSegments(
    segments: [AudioTimelineSegment],
    durationSeconds: Double
  ) -> [AudioTimelineSegment] {
    guard durationSeconds > TimelineMediaEditing.minAudioSpanSeconds + 0.05 else { return segments }
    return segments.map { segment in
      guard segment.startSeconds <= 0.001,
            isDefaultStubSpanEnd(segment.endSeconds)
      else { return segment }
      var copy = segment
      copy.endSeconds = durationSeconds
      return copy
    }
  }

  private static func clampedExportVisual(_ v: ExportVisualSettings) -> ExportVisualSettings {
    ExportVisualSettings(
      stageStyle: v.stageStyle,
      backgroundKind: v.backgroundKind,
      backgroundGradientStyle: v.backgroundGradientStyle,
      backgroundColorHex: v.backgroundColorHex,
      gradientEndColorHex: v.gradientEndColorHex,
      backgroundBlur: v.backgroundBlur,
      backgroundPadding: v.backgroundPadding,
      contentCornerRadius: v.contentCornerRadius,
      contentInset: v.contentInset,
      dropShadowOpacity: v.dropShadowOpacity,
      shadowRadius: v.shadowRadius,
      shadowYOffset: v.shadowYOffset,
      enabledForDisplayCapture: v.enabledForDisplayCapture,
      deviceFramePreset: v.deviceFramePreset
    )
  }

  /// Preset id is stored as a string raw value; unknown values fall back to `.p1080p60`.
  private static func decodedPresetID(from c: KeyedDecodingContainer<CodingKeys>) throws -> ExportPresetID {
    guard let raw = try c.decodeIfPresent(String.self, forKey: .exportPreset) else {
      return .p1080p60
    }
    return ExportPresetID(rawValue: raw) ?? .p1080p60
  }

  private static func sortedUniqueClickCues(_ cues: [CursorClickCue]) -> [CursorClickCue] {
    cues.sorted { $0.timeSeconds < $1.timeSeconds }
  }

  static func sanitizedZoomSegments(_ segments: [ZoomSegment], durationSeconds: Double?) -> [ZoomSegment] {
    let duration = durationSeconds.map { max(0, $0) }
    return segments
      .map { segment in
        var s = segment
        if let duration {
          s.startSeconds = max(0, min(duration, s.startSeconds))
          s.endSeconds = max(0, min(duration, s.endSeconds))
        }
        if s.endSeconds < s.startSeconds {
          swap(&s.startSeconds, &s.endSeconds)
        }
        if s.endSeconds - s.startSeconds < TimelineKeyframeSanitize.minZoomSpanSeconds {
          s.endSeconds = duration.map { min($0, s.startSeconds + TimelineKeyframeSanitize.minZoomSpanSeconds) }
            ?? (s.startSeconds + TimelineKeyframeSanitize.minZoomSpanSeconds)
        }
        s.inEndSeconds = max(s.startSeconds, min(s.endSeconds, s.inEndSeconds))
        s.outStartSeconds = max(s.inEndSeconds, min(s.endSeconds, s.outStartSeconds))
        s.scale = TimelineKeyframeSanitize.clampedZoomScale(s.scale)
        s.anchorX = max(0, min(1, s.anchorX))
        s.anchorY = max(0, min(1, s.anchorY))
        s.syncLegacyZoomFromTargetRegion()
        return s
      }
      .sorted { $0.startSeconds < $1.startSeconds }
  }

  static func sanitizedInputEvents(_ events: [InputEvent]) -> [InputEvent] {
    events
      .map {
        InputEvent(
          id: $0.id,
          timeSeconds: $0.timeSeconds,
          kind: $0.kind,
          x: $0.x,
          y: $0.y,
          keyCode: $0.keyCode,
          characters: $0.characters,
          modifierFlagsRaw: $0.modifierFlagsRaw
        )
      }
      .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  static func sanitizedVisualMasks(_ masks: [VisualMask], durationSeconds: Double?) -> [VisualMask] {
    let duration = durationSeconds.map { max(0, $0) }
    return masks
      .map { mask in
        var m = mask
        if let duration {
          m.startSeconds = max(0, min(duration, m.startSeconds))
          m.endSeconds = max(0, min(duration, m.endSeconds))
        }
        if m.endSeconds < m.startSeconds {
          swap(&m.startSeconds, &m.endSeconds)
        }
        if m.endSeconds - m.startSeconds < TimelineKeyframeSanitize.minHighlightSpanSeconds {
          m.endSeconds = duration.map { min($0, m.startSeconds + TimelineKeyframeSanitize.minHighlightSpanSeconds) }
            ?? (m.startSeconds + TimelineKeyframeSanitize.minHighlightSpanSeconds)
        }
        return VisualMask(
          id: m.id,
          startSeconds: m.startSeconds,
          endSeconds: m.endSeconds,
          kind: m.kind,
          originXN: m.originXN,
          originYN: m.originYN,
          widthN: m.widthN,
          heightN: m.heightN,
          opacity: m.opacity
        )
      }
      .sorted { $0.startSeconds < $1.startSeconds }
  }

  static func sanitizedCameraLayoutSegments(_ segments: [CameraLayoutSegment], durationSeconds: Double?) -> [CameraLayoutSegment] {
    let duration = durationSeconds.map { max(0, $0) }
    return segments
      .map { segment in
        var s = segment
        if let duration {
          s.startSeconds = max(0, min(duration, s.startSeconds))
          s.endSeconds = max(0, min(duration, s.endSeconds))
        }
        if s.endSeconds < s.startSeconds {
          swap(&s.startSeconds, &s.endSeconds)
        }
        return CameraLayoutSegment(
          id: s.id,
          startSeconds: s.startSeconds,
          endSeconds: max(s.endSeconds, s.startSeconds + 0.1),
          layout: s.layout,
          originXN: s.originXN,
          originYN: s.originYN,
          widthN: s.widthN,
          heightN: s.heightN,
          cornerRadiusPts: s.cornerRadiusPts,
          isMirrored: s.isMirrored,
          shrinkDuringZoom: s.shrinkDuringZoom
        )
      }
      .sorted { $0.startSeconds < $1.startSeconds }
  }

  static func `default`(mediaURL: URL, source: Source) -> RecordingProject {
    RecordingProject(
      schemaVersion: Schema.currentVersion,
      id: UUID(),
      createdAt: Date(),
      title: defaultTitle(createdAt: Date()),
      source: source,
      mediaURL: mediaURL,
      cursorSamples: [],
      exportPreset: .matchSource60,
      outputAspectRatio: .sixteenNine,
      stylePreset: .cursorFocus,
      styleSettings: StyleSettings(),
      cursorHighlightRegions: [],
      exportVisualSettings: ExportVisualSettings.defaulted(forSourceKind: source.kind),
      timeline: TimelineModel.singleClip(mediaURL: mediaURL),
      zoomSegments: []
    )
  }

  private static func defaultTitle(createdAt: Date) -> String {
    formattedAutoTitle(
      createdAt: createdAt,
      recordingLabel: autoTitlePrefixJapanese,
      locale: Locale(identifier: "ja_JP")
    )
  }

  static let autoTitlePrefixJapanese = "収録"
  static let autoTitlePrefixEnglish = "Recording"

  static func formattedAutoTitle(createdAt: Date, recordingLabel: String, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "\(recordingLabel) \(formatter.string(from: createdAt))"
  }

  static func isAutoGeneratedTitle(_ title: String, createdAt: Date) -> Bool {
    if title == formattedAutoTitle(
      createdAt: createdAt,
      recordingLabel: autoTitlePrefixJapanese,
      locale: Locale(identifier: "ja_JP")
    ) {
      return true
    }
    if title == formattedAutoTitle(
      createdAt: createdAt,
      recordingLabel: autoTitlePrefixEnglish,
      locale: Locale(identifier: "en_US")
    ) {
      return true
    }
    return title.hasPrefix("\(autoTitlePrefixJapanese) ")
  }

  static func localizedDisplayTitle(
    storedTitle: String,
    createdAt: Date,
    recordingLabel: String,
    locale: Locale
  ) -> String {
    guard isAutoGeneratedTitle(storedTitle, createdAt: createdAt) else { return storedTitle }
    return formattedAutoTitle(createdAt: createdAt, recordingLabel: recordingLabel, locale: locale)
  }
}

extension RecordingProject {
  /// Subtract source start so keys land on `[0, compositionDuration]` (mixed composition timeline).
  static func shiftZoomKeyframesForCompositionExport(
    _ keyframes: [RecordingProject.ZoomKeyframe],
    sourceStartSeconds: Double,
    compositionDurationSeconds: Double
  ) -> [RecordingProject.ZoomKeyframe] {
    let dur = max(TimelineKeyframeSanitize.minZoomSpanSeconds, compositionDurationSeconds)
    return keyframes.map { kf in
      var k = kf
      k.startSeconds = max(0, min(dur, k.startSeconds - sourceStartSeconds))
      k.inEndSeconds = max(0, min(dur, k.inEndSeconds - sourceStartSeconds))
      k.outStartSeconds = max(0, min(dur, k.outStartSeconds - sourceStartSeconds))
      k.endSeconds = max(0, min(dur, k.endSeconds - sourceStartSeconds))
      if k.endSeconds <= k.startSeconds + TimelineKeyframeSanitize.minZoomSpanSeconds {
        k.endSeconds = min(dur, k.startSeconds + TimelineKeyframeSanitize.minZoomSpanSeconds)
      }
      k.inEndSeconds = max(k.startSeconds, min(k.endSeconds, k.inEndSeconds))
      k.outStartSeconds = max(k.inEndSeconds, min(k.endSeconds, k.outStartSeconds))
      return k
    }
  }

  static func shiftTextOverlaysForCompositionExport(
    _ overlays: [RecordingProject.TextOverlayAnnotation],
    sourceStartSeconds: Double
  ) -> [RecordingProject.TextOverlayAnnotation] {
    overlays.map { o in
      var c = o
      c.startSeconds = o.startSeconds - sourceStartSeconds
      c.endSeconds = o.endSeconds - sourceStartSeconds
      return c
    }
  }

  static func shiftClickCuesForCompositionExport(
    _ cues: [RecordingProject.CursorClickCue],
    sourceStartSeconds: Double
  ) -> [RecordingProject.CursorClickCue] {
    cues.map { c in
      var n = c
      n.timeSeconds = c.timeSeconds - sourceStartSeconds
      return n
    }
  }

  static func shiftHighlightRegionsForCompositionExport(
    _ regions: [RecordingProject.CursorHighlightRegion],
    sourceStartSeconds: Double
  ) -> [RecordingProject.CursorHighlightRegion] {
    regions.map { region in
      var shifted = region
      shifted.startSeconds = region.startSeconds - sourceStartSeconds
      shifted.endSeconds = region.endSeconds - sourceStartSeconds
      return shifted
    }
  }

  static func clampedSortedClickCueTimes(_ cues: [RecordingProject.CursorClickCue], compositionDurationSeconds: Double) -> [RecordingProject.CursorClickCue] {
    let d = max(0, compositionDurationSeconds)
    return cues
      .map {
        var c = $0
        c.timeSeconds = max(0, min(d, c.timeSeconds))
        return c
      }
      .sorted { $0.timeSeconds < $1.timeSeconds }
  }

  func sourceSecondsForPreviewPlayback(_ seconds: Double) -> Double {
    timeline.sourceSeconds(forTimelineSeconds: seconds)
      ?? seconds
  }

  func activePreviewZoomKeyframe(atPlaybackSeconds seconds: Double) -> ZoomKeyframe? {
    let sourceSeconds = sourceSecondsForPreviewPlayback(seconds)
    let candidates = zoomSegments.map(\.asZoomKeyframe)
    return candidates
      .filter { keyframe in
        sourceSeconds >= keyframe.startSeconds - 1e-9
          && sourceSeconds <= keyframe.endSeconds + 1e-9
      }
      .sorted { lhs, rhs in
        if abs(lhs.startSeconds - rhs.startSeconds) > 1e-9 {
          return lhs.startSeconds < rhs.startSeconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .last
  }

  func autoZoomMotionFrame(atSourceSeconds seconds: Double) -> AutoZoomMotionFrame? {
    guard let frames = autoZoomAnalysis?.motionFrames,
      let state = AutoZoomMotionPlan(frames: frames).state(at: seconds)
    else {
      return nil
    }
    return AutoZoomMotionFrame(
      timeSeconds: state.timeSeconds,
      anchorX: state.anchorX,
      anchorY: state.anchorY,
      scale: state.scale
    )
  }
}

extension RecordingProject {
  /// Timeline editing helpers used by the editor and exporter.
  enum TimelineEditing {
    static let minClipDurationSeconds: Double = 0.05
    static let minInteractiveClipDurationSeconds: Double = 0.1
    static let defaultSplitGuardSeconds: Double = 0.08
    static let defaultSpeedRate: Double = 1
  }

  struct TimelineTimeMapping: Equatable {
    var sourceStartSeconds: Double
    var sourceEndSeconds: Double
    var timelineStartSeconds: Double
    var rate: Double

    var sourceDurationSeconds: Double {
      max(0, sourceEndSeconds - sourceStartSeconds)
    }

    var timelineDurationSeconds: Double {
      guard rate > 1e-9 else { return sourceDurationSeconds }
      return sourceDurationSeconds / rate
    }

    var timelineEndSeconds: Double {
      timelineStartSeconds + timelineDurationSeconds
    }

    func timelineSeconds(forSourceSeconds seconds: Double) -> Double? {
      guard seconds >= sourceStartSeconds - 1e-9, seconds <= sourceEndSeconds + 1e-9 else {
        return nil
      }
      return timelineStartSeconds + max(0, seconds - sourceStartSeconds) / max(rate, 1e-9)
    }

    func sourceSeconds(forTimelineSeconds seconds: Double) -> Double? {
      guard seconds >= timelineStartSeconds - 1e-9, seconds <= timelineEndSeconds + 1e-9 else {
        return nil
      }
      return sourceStartSeconds + max(0, seconds - timelineStartSeconds) * max(rate, 1e-9)
    }
  }

  /// Canonical bounds checks for timeline keyframes (**does not** merge overlaps; exporter picks latest-start wins).
  enum TimelineKeyframeSanitize {
    static let minZoomSpanSeconds: Double = 0.1
    static let minHighlightSpanSeconds: Double = 0.1
    static let maxVisualMaskCount: Int = 12
    static let minZoomScale: Double = 1
    static let maxZoomScale: Double = 3

    static func clampedZoomScale(_ value: Double) -> Double {
      max(minZoomScale, min(maxZoomScale, value))
    }

    static func zoomFrames(_ keyframes: [ZoomKeyframe], durationSeconds: Double) -> [ZoomKeyframe] {
      let duration = max(0, durationSeconds)
      return keyframes
        .map { kf in
          var kf = kf
          kf.startSeconds = max(0, min(duration, kf.startSeconds))
          kf.endSeconds = max(0, min(duration, kf.endSeconds))
          if kf.endSeconds < kf.startSeconds {
            swap(&kf.startSeconds, &kf.endSeconds)
          }
          if kf.endSeconds - kf.startSeconds < minZoomSpanSeconds {
            kf.endSeconds = min(duration, kf.startSeconds + minZoomSpanSeconds)
          }
          kf.inEndSeconds = max(kf.startSeconds, min(kf.endSeconds, kf.inEndSeconds))
          kf.outStartSeconds = max(kf.inEndSeconds, min(kf.endSeconds, kf.outStartSeconds))
          kf.scale = clampedZoomScale(kf.scale)
          kf.anchorX = max(0, min(1, kf.anchorX))
          kf.anchorY = max(0, min(1, kf.anchorY))
          var segment = ZoomSegment.fromKeyframe(kf)
          segment.syncLegacyZoomFromTargetRegion()
          kf = segment.asZoomKeyframe
          return kf
        }
        .sorted { $0.startSeconds < $1.startSeconds }
    }

    static func highlightRegions(_ regions: [CursorHighlightRegion], durationSeconds: Double) -> [CursorHighlightRegion] {
      let duration = max(0, durationSeconds)
      return regions
        .map { r in
          var r = r
          r.startSeconds = max(0, min(duration, r.startSeconds))
          r.endSeconds = max(0, min(duration, r.endSeconds))
          if r.endSeconds < r.startSeconds {
            swap(&r.startSeconds, &r.endSeconds)
          }
          if r.endSeconds - r.startSeconds < minHighlightSpanSeconds {
            r.endSeconds = min(duration, r.startSeconds + minHighlightSpanSeconds)
          }
          return r
        }
        .sorted { $0.startSeconds < $1.startSeconds }
    }
  }
}

extension RecordingProject.TimelineModel {
  enum ClipDisplayMode {
    case singleSource
    case timeline
  }

  struct ClipDisplayRange: Equatable {
    var startSeconds: Double
    var endSeconds: Double

    var durationSeconds: Double {
      max(0, endSeconds - startSeconds)
    }
  }

  var activeClips: [Clip] {
    clips
      .filter { $0.durationSeconds > RecordingProject.TimelineEditing.minClipDurationSeconds }
      .sorted { lhs, rhs in
        if abs(lhs.timelineStartSeconds - rhs.timelineStartSeconds) > 1e-9 {
          return lhs.timelineStartSeconds < rhs.timelineStartSeconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
  }

  var activeDurationSeconds: Double {
    activeClips
      .map { $0.timelineStartSeconds + $0.durationSeconds }
      .max() ?? 0
  }

  var hasActiveClips: Bool {
    !activeClips.isEmpty
  }

  var singleEditableClip: Clip? {
    let ordered = activeClips
    return ordered.count == 1 ? ordered[0] : nil
  }

  mutating func ensureSingleEditableClip(
    mediaURL: URL,
    sourceStartSeconds: Double = 0,
    sourceEndSeconds: Double? = nil,
    assetDurationSeconds: Double
  ) {
    guard !hasActiveClips else { return }
    let sourceStart = max(0, sourceStartSeconds)
    let sourceEnd = max(sourceStart, sourceEndSeconds ?? assetDurationSeconds)
    let duration = max(0, sourceEnd - sourceStart)
    guard duration > RecordingProject.TimelineEditing.minClipDurationSeconds else { return }
    clips = [
      Clip(
        sourceURL: mediaURL,
        sourceStartSeconds: sourceStart,
        timelineStartSeconds: 0,
        durationSeconds: duration
      ),
    ]
    speedSegments = []
  }

  mutating func setSingleClipLeadingSourceSeconds(_ rawStart: Double, assetDurationSeconds: Double) -> Bool {
    adjustSingleClipBoundary(.leading, sourceSeconds: rawStart, assetDurationSeconds: assetDurationSeconds)
  }

  mutating func setSingleClipTrailingSourceSeconds(_ rawEnd: Double, assetDurationSeconds: Double) -> Bool {
    adjustSingleClipBoundary(.trailing, sourceSeconds: rawEnd, assetDurationSeconds: assetDurationSeconds)
  }

  private enum SingleClipBoundary {
    case leading
    case trailing
  }

  private mutating func adjustSingleClipBoundary(
    _ boundary: SingleClipBoundary,
    sourceSeconds rawSeconds: Double,
    assetDurationSeconds: Double
  ) -> Bool {
    guard let clip = singleEditableClip,
      let index = clips.firstIndex(where: { $0.id == clip.id })
    else { return false }

    let rate = speedRate(for: clip)
    let safeRate = max(rate, 1e-9)
    let assetEnd = max(clip.sourceStartSeconds, assetDurationSeconds)
    let minSourceDuration = RecordingProject.TimelineEditing.minInteractiveClipDurationSeconds * safeRate
    let currentSourceStart = max(0, min(clip.sourceStartSeconds, assetEnd))
    let currentSourceEnd = max(currentSourceStart, min(assetEnd, sourceEndSeconds(for: clip)))

    let sourceStart: Double
    let sourceEnd: Double
    switch boundary {
    case .leading:
      sourceEnd = currentSourceEnd
      sourceStart = min(max(0, rawSeconds), max(0, sourceEnd - minSourceDuration))
    case .trailing:
      sourceStart = currentSourceStart
      sourceEnd = min(assetEnd, max(sourceStart + minSourceDuration, rawSeconds))
    }

    let sourceDuration = max(minSourceDuration, sourceEnd - sourceStart)
    let timelineDuration = sourceDuration / safeRate
    guard timelineDuration > RecordingProject.TimelineEditing.minClipDurationSeconds else { return false }

    let oldStart = clip.timelineStartSeconds
    let oldDuration = clip.durationSeconds
    clips[index].sourceStartSeconds = sourceStart
    clips[index].durationSeconds = timelineDuration
    clips = Self.reflowed(clips)

    speedSegments.removeAll { segment in
      max(segment.startSeconds, oldStart) < min(segment.endSeconds, oldStart + oldDuration)
    }
    if abs(rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9,
      let updated = clips.first(where: { $0.id == clip.id }) {
      speedSegments.append(
        SpeedSegment(
          startSeconds: updated.timelineStartSeconds,
          endSeconds: updated.timelineStartSeconds + updated.durationSeconds,
          rate: rate
        )
      )
      speedSegments = speedSegments.sorted { $0.startSeconds < $1.startSeconds }
    }
    return true
  }

  mutating func splitClip(atTimelineSeconds seconds: Double) -> UUID? {
    var ordered = activeClips
    guard let index = ordered.firstIndex(where: { clip in
      let local = seconds - clip.timelineStartSeconds
      return local > RecordingProject.TimelineEditing.defaultSplitGuardSeconds
        && local < clip.durationSeconds - RecordingProject.TimelineEditing.defaultSplitGuardSeconds
    }) else {
      return nil
    }

    let clip = ordered[index]
    let firstDuration = seconds - clip.timelineStartSeconds
    let secondDuration = clip.durationSeconds - firstDuration
    guard firstDuration > RecordingProject.TimelineEditing.minClipDurationSeconds,
      secondDuration > RecordingProject.TimelineEditing.minClipDurationSeconds
    else {
      return nil
    }

    ordered[index].durationSeconds = firstDuration
    let rate = speedRate(for: clip)
    let second = Clip(
      sourceURL: clip.sourceURL,
      sourceStartSeconds: clip.sourceStartSeconds + firstDuration * rate,
      timelineStartSeconds: seconds,
      durationSeconds: secondDuration
    )
    ordered.insert(second, at: index + 1)
    clips = ordered
    return second.id
  }

  mutating func deleteClip(id: UUID) -> Bool {
    var ordered = activeClips
    guard let index = ordered.firstIndex(where: { $0.id == id }) else { return false }
    ordered.remove(at: index)
    clips = Self.reflowed(ordered)
    speedSegments = speedSegments.filter { segment in
      segment.endSeconds <= activeDurationSeconds + 1e-9
    }
    return true
  }

  mutating func setSpeed(rate rawRate: Double, forClipID clipID: UUID) -> Bool {
    let rate = SpeedSegment.clampedRate(rawRate)
    var ordered = activeClips
    guard let index = ordered.firstIndex(where: { $0.id == clipID }) else { return false }
    let oldStart = ordered[index].timelineStartSeconds
    let oldDuration = ordered[index].durationSeconds
    let sourceDuration = sourceDurationForClip(ordered[index])
    let newDuration = max(
      RecordingProject.TimelineEditing.minClipDurationSeconds,
      sourceDuration / rate
    )

    ordered[index].durationSeconds = newDuration
    clips = Self.reflowed(ordered)
    guard let updated = clips.first(where: { $0.id == clipID }) else { return false }
    speedSegments.removeAll { segment in
      max(segment.startSeconds, oldStart) < min(segment.endSeconds, oldStart + oldDuration)
    }
    if abs(rate - RecordingProject.TimelineEditing.defaultSpeedRate) > 1e-9 {
      speedSegments.append(
        SpeedSegment(
          startSeconds: updated.timelineStartSeconds,
          endSeconds: updated.timelineStartSeconds + updated.durationSeconds,
          rate: rate
        )
      )
    }
    speedSegments = speedSegments.sorted { $0.startSeconds < $1.startSeconds }
    return true
  }

  func sourceDurationForClip(_ clip: Clip) -> Double {
    clip.durationSeconds * speedRate(for: clip)
  }

  func sourceEndSeconds(for clip: Clip) -> Double {
    clip.sourceStartSeconds + sourceDurationForClip(clip)
  }

  func sourceRange(for clip: Clip) -> ClipDisplayRange {
    ClipDisplayRange(
      startSeconds: clip.sourceStartSeconds,
      endSeconds: sourceEndSeconds(for: clip)
    )
  }

  func previewSeconds(forSourceSeconds seconds: Double, in clip: Clip) -> Double {
    max(0, seconds - clip.sourceStartSeconds) / max(speedRate(for: clip), 1e-9)
  }

  func sourceSeconds(forPreviewSeconds seconds: Double, in clip: Clip) -> Double {
    clip.sourceStartSeconds + max(0, seconds) * max(speedRate(for: clip), 1e-9)
  }

  func displayRange(for clip: Clip, mode: ClipDisplayMode) -> ClipDisplayRange {
    switch mode {
    case .singleSource:
      return sourceRange(for: clip)
    case .timeline:
      return ClipDisplayRange(
        startSeconds: clip.timelineStartSeconds,
        endSeconds: clip.timelineStartSeconds + clip.durationSeconds
      )
    }
  }

  func speedRate(for clip: Clip) -> Double {
    speedRate(
      forTimelineRangeStart: clip.timelineStartSeconds,
      end: clip.timelineStartSeconds + clip.durationSeconds
    )
  }

  func speedRate(forTimelineRangeStart start: Double, end: Double) -> Double {
    let matches = speedSegments.filter { segment in
      segment.startSeconds <= start + 1e-9 && segment.endSeconds >= end - 1e-9
    }
    return matches.last?.rate ?? RecordingProject.TimelineEditing.defaultSpeedRate
  }

  func timeMappings() -> [RecordingProject.TimelineTimeMapping] {
    activeClips.map { clip in
      let rate = speedRate(for: clip)
      let sourceDuration = sourceDurationForClip(clip)
      return RecordingProject.TimelineTimeMapping(
        sourceStartSeconds: clip.sourceStartSeconds,
        sourceEndSeconds: clip.sourceStartSeconds + sourceDuration,
        timelineStartSeconds: clip.timelineStartSeconds,
        rate: rate
      )
    }
  }

  func timelineSeconds(forSourceSeconds seconds: Double) -> [Double] {
    timeMappings().compactMap { $0.timelineSeconds(forSourceSeconds: seconds) }
  }

  func sourceSeconds(forTimelineSeconds seconds: Double) -> Double? {
    timeMappings()
      .first { seconds >= $0.timelineStartSeconds - 1e-9 && seconds <= $0.timelineEndSeconds + 1e-9 }?
      .sourceSeconds(forTimelineSeconds: seconds)
  }

  private static func reflowed(_ clips: [Clip]) -> [Clip] {
    var cursor = 0.0
    return clips
      .filter { $0.durationSeconds > RecordingProject.TimelineEditing.minClipDurationSeconds }
      .sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
      .map { clip in
        var c = clip
        c.timelineStartSeconds = cursor
        cursor += c.durationSeconds
        return c
      }
  }

}

extension RecordingProject.ExportVisualSettings {
  /// Corner radius used at export: clamps the model value, then caps by the shorter card side (see `Exporter` stage layout).
  static func effectiveCornerRadiusPts(requested: Double, contentRectSideMinPts: CGFloat) -> CGFloat {
    let req = RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.clampedCornerRadiusPts(requested)
    guard contentRectSideMinPts > 1 else { return 0 }
    let capHalf = CGFloat(req) <= contentRectSideMinPts / 2 * 0.98 ? CGFloat(req) : contentRectSideMinPts / 2 * 0.98
    return max(0, capHalf)
  }
}
