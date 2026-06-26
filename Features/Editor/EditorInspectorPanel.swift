import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum EditorInspectorSection: String, CaseIterable, Identifiable {
  case background
  case zoom
  case cursor
  case mask
  case captions
  case camera
  case audio
  case export

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .background: return "photo.artframe"
    case .zoom: return "plus.magnifyingglass"
    case .cursor: return "cursorarrow.motionlines"
    case .mask: return "eye.slash"
    case .captions: return "captions.bubble"
    case .camera: return "video"
    case .audio: return "waveform"
    case .export: return "square.and.arrow.up"
    }
  }

  var title: String {
    switch self {
    case .background: return "Background"
    case .zoom: return "Zoom"
    case .cursor: return "Cursor"
    case .mask: return "Mask"
    case .captions: return "Captions"
    case .camera: return "Camera"
    case .audio: return "Audio"
    case .export: return "Export"
    }
  }

  static func railGroups(includingCamera: Bool) -> [[EditorInspectorSection]] {
    var media: [EditorInspectorSection] = [.audio]
    if includingCamera {
      media.insert(.camera, at: 0)
    }
    return [
      [.background, .cursor],
      [.zoom, .mask, .captions],
      media,
    ]
  }
}

enum EditorBackgroundMode: String, CaseIterable, Identifiable {
  case wallpaper
  case gradient
  case color
  case image

  var id: String { rawValue }

  var title: String {
    switch self {
    case .wallpaper: return "Wallpaper"
    case .gradient: return "Gradient"
    case .color: return "Color"
    case .image: return "Image"
    }
  }

  init(settings: RecordingProject.ExportVisualSettings) {
    switch settings.backgroundKind {
    case .solid:
      self = .color
    case .linearGradientVertical:
      self = settings.backgroundColorHex == RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageBackgroundFallbackHex
        && settings.gradientEndColorHex == RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageGradientEndFallbackHex
        ? .wallpaper
        : .gradient
    }
  }
}

struct EditorToolChip: View {
  var title: String
  var systemImage: String
  var selected: Bool

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(
        selected ? EditorPalette.brand.opacity(0.18) : Color.primary.opacity(0.055),
        in: Capsule(style: .continuous)
      )
      .overlay {
        Capsule(style: .continuous)
          .stroke(selected ? EditorPalette.brand.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
      }
  }
}

struct EditorInspectorPanel: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  @Environment(AppLanguageStore.self) private var languageStore

  var project: RecordingProject
  var durationSeconds: Double
  var currentPlayheadSeconds: Double
  @Binding var selectedSection: EditorInspectorSection
  @Binding var selectedTimelineEffect: EditorTimelineEffectSelection?
  @Binding var backgroundMode: EditorBackgroundMode
  var updateVisuals: ((inout RecordingProject.ExportVisualSettings) -> Void) -> Void
  var onAddZoom: () -> Void
  var onCommitZoomEffectRange: (UUID, Double, Double, Double, Double) -> Void
  var onCommitCaptionEffectRange: (UUID, Double, Double) -> Void
  var onCommitMaskEffectRange: (UUID, Double, Double) -> Void
  var isExporting: Bool
  var exportAction: () -> Void
  var captionGenerator: CaptionGenerator

  var body: some View {
    HStack(spacing: 0) {
      inspectorRail

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(languageStore.localized(selectedSection.title))
            .font(.headline.weight(.semibold))
            .lineLimit(1)

          if selectedSection == .background {
            BackgroundInspector(
              project: project,
              backgroundMode: $backgroundMode,
              updateVisuals: updateVisuals
            )
          } else if selectedSection == .zoom {
            ZoomInspector(
              project: project,
              durationSeconds: durationSeconds,
              selectedTimelineEffect: $selectedTimelineEffect,
              onAddZoom: onAddZoom
            )
          } else if selectedSection == .cursor {
            CursorInspector(project: project)
          } else if selectedSection == .mask {
            MaskInspector(
              project: project,
              durationSeconds: durationSeconds,
              currentPlayheadSeconds: currentPlayheadSeconds,
              selectedTimelineEffect: $selectedTimelineEffect,
              onCommitMaskEffectRange: onCommitMaskEffectRange
            )
          } else if selectedSection == .captions {
            CaptionsInspector(
              project: project,
              durationSeconds: durationSeconds,
              selectedTimelineEffect: selectedTimelineEffect,
              onCommitCaptionEffectRange: onCommitCaptionEffectRange,
              captionGenerator: captionGenerator
            )
          } else if selectedSection == .camera {
            CameraInspector(project: project, durationSeconds: durationSeconds)
          } else if selectedSection == .audio {
            AudioInspector(project: project, selectedTimelineEffect: selectedTimelineEffect)
          } else if selectedSection == .export {
            ExportInspector(project: project, isExporting: isExporting, exportAction: exportAction)
          }
        }
        .padding(.horizontal, EditorLayout.panelInset + 4)
        .padding(.vertical, EditorLayout.panelInset + 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .background(EditorPalette.panelBackground.opacity(0.38))
    }
    .onAppear {
      normalizeSelectedSection()
    }
    .onChange(of: project.secondaryRecording) { _, _ in
      normalizeSelectedSection()
    }
  }

  private var inspectorRail: some View {
    let groups = EditorInspectorSection.railGroups(includingCamera: project.secondaryRecording != nil)

    return VStack(spacing: 8) {
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        if index > 0 {
          inspectorRailDivider
        }
        VStack(spacing: 6) {
          ForEach(group) { section in
            InspectorSectionButton(
              section: section,
              isSelected: section == selectedSection
            ) {
              selectedSection = section
            }
          }
        }
      }

      Spacer(minLength: 0)

      inspectorRailDivider

      InspectorSectionButton(
        section: .export,
        isSelected: selectedSection == .export,
        emphasized: true
      ) {
        selectedSection = .export
      }
    }
    .padding(.top, EditorLayout.panelInset)
    .padding(.bottom, EditorLayout.panelInset)
    .frame(width: EditorLayout.inspectorRailWidth)
    .background(EditorPalette.panelBackground.opacity(0.7))
  }

  private var inspectorRailDivider: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.08))
      .frame(width: 28, height: 1)
  }

  private func normalizeSelectedSection() {
    if selectedSection == .camera, project.secondaryRecording == nil {
      selectedSection = .background
    }
  }
}

struct InspectorSectionButton: View {
  @Environment(AppLanguageStore.self) private var languageStore
  var section: EditorInspectorSection
  var isSelected: Bool
  var emphasized: Bool = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: section.icon)
          .font(.system(size: 14, weight: .semibold))
        Text(languageStore.localized(section.title))
          .font(.system(size: 8, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .frame(width: EditorLayout.inspectorRailButtonWidth, height: EditorLayout.inspectorRailButtonHeight)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .foregroundStyle(
      isSelected
        ? EditorPalette.brandStrong
        : (emphasized ? Color.primary.opacity(0.72) : Color.primary.opacity(0.46))
    )
    .background(
      isSelected ? EditorPalette.brand.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: EditorLayout.controlCornerRadius, style: .continuous)
    )
    .help(languageStore.localized(section.title))
    .accessibilityLabel(languageStore.localized(section.title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct ZoomInspector: View {
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(ProjectStore.self) private var projectStore
  var project: RecordingProject
  var durationSeconds: Double
  @Binding var selectedTimelineEffect: EditorTimelineEffectSelection?
  var onAddZoom: () -> Void

  private var sortedSegments: [RecordingProject.ZoomSegment] {
    project.zoomSegments.sorted { lhs, rhs in
      if lhs.startSeconds != rhs.startSeconds {
        return lhs.startSeconds < rhs.startSeconds
      }
      return lhs.endSeconds < rhs.endSeconds
    }
  }

  private var focusedSegmentID: UUID? {
    if case .zoom(let id) = selectedTimelineEffect {
      return id
    }
    return sortedSegments.first?.id
  }

  private var focusedSegment: RecordingProject.ZoomSegment? {
    guard let focusedSegmentID else { return nil }
    return project.zoomSegments.first(where: { $0.id == focusedSegmentID })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Button(action: onAddZoom) {
        Label(languageStore.localized("Add zoom"), systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)

      if sortedSegments.isEmpty {
        InspectorEmptyHint(text: "タイムラインの効果を選ぶか、上のボタンでズームを追加します。")
      } else {
        if sortedSegments.count > 1 {
          zoomSegmentList
        }

        if let segment = focusedSegment {
          zoomDetailEditor(segment: segment)
        }
      }
    }
  }

  private var zoomSegmentList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(languageStore.localized("登録済みのズーム"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(Array(sortedSegments.enumerated()), id: \.element.id) { index, segment in
        zoomSegmentListRow(index: index + 1, segment: segment)
      }
    }
  }

  private func zoomSegmentListRow(index: Int, segment: RecordingProject.ZoomSegment) -> some View {
    let isSelected = focusedSegmentID == segment.id
    return Button {
      selectedTimelineEffect = .zoom(segment.id)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "plus.magnifyingglass")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isSelected ? EditorPalette.brandStrong : .secondary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 2) {
          Text(languageStore.localizedFormat("Zoom %@", "\(index)"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
          Text(zoomPeriodSummary(segment))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(EditorPalette.brandStrong)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? EditorPalette.brand.opacity(0.14) : Color.primary.opacity(0.04),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            isSelected ? EditorPalette.brandStrong.opacity(0.55) : Color.primary.opacity(0.08),
            lineWidth: isSelected ? 1.5 : 1
          )
      }
    }
    .buttonStyle(.plain)
  }

  private func zoomPeriodSummary(_ segment: RecordingProject.ZoomSegment) -> String {
    let start = editorFormatTime(segment.startSeconds, fractional: true)
    let end = editorFormatTime(segment.endSeconds, fractional: true)
    let duration = editorFormatTime(max(0, segment.endSeconds - segment.startSeconds), fractional: true)
    return "\(start) – \(end) (\(duration))"
  }

  private func zoomDetailEditor(segment: RecordingProject.ZoomSegment) -> some View {
    InspectorCard(isSelected: selectedTimelineEffect == .zoom(segment.id)) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text(zoomPeriodSummary(segment))
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .monospacedDigit()
          Text(languageStore.localized("タイムラインで開始・終了を調整できます。ズームは重なりません。"))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        InspectorSlider(
          title: "ズームの強さ",
          value: Binding(
            get: { segment.targetZoomLevel },
            set: { updateZoomLevel(segment: segment, zoomLevel: $0) }
          ),
          range: RecordingProject.ZoomSegment.minZoomLevel...RecordingProject.ZoomSegment.maxZoomLevel,
          step: 0.05
        )

        zoomRampEditors(segment: segment)
      }
    }
  }

  private func zoomRampEditors(segment: RecordingProject.ZoomSegment) -> some View {
    let span = max(0, segment.endSeconds - segment.startSeconds)
    let maxRamp = max(0.05, span / 2)
    let rampIn = max(0, segment.inEndSeconds - segment.startSeconds)
    let rampOut = max(0, segment.endSeconds - segment.outStartSeconds)

    return VStack(alignment: .leading, spacing: 10) {
      Text(languageStore.localized("動きのなめらかさ"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      InspectorSlider(
        title: "拡大にかかる時間",
        value: Binding(
          get: { min(rampIn, maxRamp) },
          set: { setRampIn(segment: segment, seconds: $0) }
        ),
        range: 0...maxRamp,
        step: 0.05
      )

      InspectorSlider(
        title: "縮小にかかる時間",
        value: Binding(
          get: { min(rampOut, maxRamp) },
          set: { setRampOut(segment: segment, seconds: $0) }
        ),
        range: 0...maxRamp,
        step: 0.05
      )
    }
  }

  private func updateSegment(id: UUID, mutate: @escaping (inout RecordingProject.ZoomSegment) -> Void) {
    projectStore.applyToCurrent { project in
      guard let index = project.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
      mutate(&project.zoomSegments[index])
      syncZoomKeyframes(project: &project)
    }
  }

  private func syncZoomKeyframes(project: inout RecordingProject) {
    project.zoomSegments = RecordingProjectEditorZoomSanitizer.sanitizedSegments(
      project.zoomSegments,
      durationSeconds: durationSeconds
    )
  }

  private func zoomDoubleBinding(
    id: UUID,
    get: KeyPath<RecordingProject.ZoomSegment, Double>,
    set: @escaping (inout RecordingProject.ZoomSegment, Double) -> Void
  ) -> Binding<Double> {
    Binding(
      get: { project.zoomSegments.first(where: { $0.id == id })?[keyPath: get] ?? 0 },
      set: { value in updateSegment(id: id) { set(&$0, value) } }
    )
  }

  private func zoomBoolBinding(
    id: UUID,
    get: KeyPath<RecordingProject.ZoomSegment, Bool>,
    set: @escaping (inout RecordingProject.ZoomSegment, Bool) -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { project.zoomSegments.first(where: { $0.id == id })?[keyPath: get] ?? false },
      set: { value in updateSegment(id: id) { set(&$0, value) } }
    )
  }

  private func zoomModeBinding(id: UUID) -> Binding<RecordingProject.ZoomSegment.Mode> {
    Binding(
      get: { project.zoomSegments.first(where: { $0.id == id })?.mode ?? .manual },
      set: { value in updateSegment(id: id) { $0.mode = value } }
    )
  }

  private func setRampIn(segment: RecordingProject.ZoomSegment, seconds: Double) {
    let clamped = max(0, seconds)
    updateSegment(id: segment.id) { s in
      // 寄り終わりは out 始まりを超えないようにする（ホールドが負にならない）。
      s.inEndSeconds = max(s.startSeconds, min(s.outStartSeconds, s.startSeconds + clamped))
    }
  }

  private func setRampOut(segment: RecordingProject.ZoomSegment, seconds: Double) {
    let clamped = max(0, seconds)
    updateSegment(id: segment.id) { s in
      s.outStartSeconds = min(s.endSeconds, max(s.inEndSeconds, s.endSeconds - clamped))
    }
  }

  private func updateZoomLevel(segment: RecordingProject.ZoomSegment, zoomLevel: Double) {
    updateSegment(id: segment.id) { segment in
      segment.setTargetZoomLevel(zoomLevel)
    }
  }
}

struct CursorInspector: View {
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(ProjectStore.self) private var projectStore
  var project: RecordingProject

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      InspectorSlider(
        title: languageStore.localized("Cursor size"),
        value: cursorDoubleBinding(\.sizeScale) { $0.sizeScale = $1 },
        range: 0.5...3,
        step: 0.05
      )

      VStack(alignment: .leading, spacing: 10) {
        Text(languageStore.localized("Pointer style"))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          ForEach(RecordingProject.CursorVisualSettings.PointerStyle.allCases) { style in
            CursorStyleButton(
              style: style,
              isSelected: project.cursorVisualSettings.pointerStyle == style,
              selection: cursorPointerStyleBinding()
            )
          }
        }
      }

      VStack(spacing: 0) {
        CursorToggleRow(
          title: "Visible",
          subtitle: "Show the pointer in the exported video.",
          isOn: cursorBoolBinding(\.isVisible) { $0.isVisible = $1 }
        )
        CursorToggleRow(
          title: "Click effects",
          subtitle: "Draw click feedback around pointer events.",
          isOn: cursorBoolBinding(\.showClickEffects) { $0.showClickEffects = $1 }
        )
        CursorToggleRow(
          title: "Keyboard shortcuts",
          subtitle: "Display captured key presses while editing.",
          isOn: cursorBoolBinding(\.showKeyboardShortcuts) { $0.showKeyboardShortcuts = $1 }
        )
        CursorToggleRow(
          title: "Hide when idle",
          subtitle: "Reduce pointer noise during still moments.",
          isOn: cursorBoolBinding(\.hideWhenIdle) { $0.hideWhenIdle = $1 },
          showsDivider: false
        )
      }
      .padding(.horizontal, 10)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      InspectorMetricGrid(items: [
        (languageStore.localized("Samples"), "\(project.cursorSamples.count)"),
        (languageStore.localized("Clicks"), "\(project.cursorClickCues.count)"),
        (languageStore.localized("Keys"), "\(project.inputEvents.filter { $0.kind == .keyDown }.count)"),
      ])
    }
  }

  private func cursorBoolBinding(
    _ get: KeyPath<RecordingProject.CursorVisualSettings, Bool>,
    _ set: @escaping (inout RecordingProject.CursorVisualSettings, Bool) -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { project.cursorVisualSettings[keyPath: get] },
      set: { value in
        projectStore.applyToCurrent { project in
          var settings = project.cursorVisualSettings
          set(&settings, value)
          project.cursorVisualSettings = settings
        }
      }
    )
  }

  private func cursorDoubleBinding(
    _ get: KeyPath<RecordingProject.CursorVisualSettings, Double>,
    _ set: @escaping (inout RecordingProject.CursorVisualSettings, Double) -> Void
  ) -> Binding<Double> {
    Binding(
      get: { project.cursorVisualSettings[keyPath: get] },
      set: { value in
        projectStore.applyToCurrent { project in
          var settings = project.cursorVisualSettings
          set(&settings, value)
          project.cursorVisualSettings = settings
        }
      }
    )
  }

  private func cursorPointerStyleBinding() -> Binding<RecordingProject.CursorVisualSettings.PointerStyle> {
    Binding(
      get: { project.cursorVisualSettings.pointerStyle },
      set: { value in
        projectStore.applyToCurrent { project in
          var settings = project.cursorVisualSettings
          settings.pointerStyle = value
          project.cursorVisualSettings = settings
        }
      }
    )
  }
}

struct CursorStyleButton: View {
  @Environment(AppLanguageStore.self) private var languageStore
  var style: RecordingProject.CursorVisualSettings.PointerStyle
  var isSelected: Bool
  @Binding var selection: RecordingProject.CursorVisualSettings.PointerStyle

  var body: some View {
    Button {
      selection = style
    } label: {
      VStack(spacing: 7) {
        Image(systemName: iconName)
          .font(.system(size: 18, weight: .semibold))
          .frame(height: 22)
        Text(languageStore.localized(titleKey))
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
      }
      .foregroundStyle(isSelected ? EditorPalette.brandStrong : .primary)
      .frame(maxWidth: .infinity, minHeight: 58)
      .background(
        isSelected ? EditorPalette.brand.opacity(0.14) : Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(isSelected ? EditorPalette.brandStrong.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .help(languageStore.localized(titleKey))
  }

  private var iconName: String {
    switch style {
    case .spotlight: return "scope"
    case .arrow: return "cursorarrow"
    case .arrowWithRing: return "cursorarrow.click"
    case .dot: return "circle.fill"
    }
  }

  private var titleKey: String {
    switch style {
    case .spotlight: return "Spotlight"
    case .arrow: return "Arrow"
    case .arrowWithRing: return "Arrow + Ring"
    case .dot: return "Dot"
    }
  }
}

struct CursorToggleRow: View {
  @Environment(AppLanguageStore.self) private var languageStore
  var title: String
  var subtitle: String
  @Binding var isOn: Bool
  var showsDivider: Bool = true

  var body: some View {
    Toggle(isOn: $isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(languageStore.localized(title))
          .font(.callout.weight(.semibold))
        Text(languageStore.localized(subtitle))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(.vertical, 11)
    .overlay(alignment: .bottom) {
      if showsDivider {
        Rectangle()
          .fill(Color.primary.opacity(0.07))
          .frame(height: 1)
      }
    }
  }
}

struct MaskInspector: View {
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  var project: RecordingProject
  var durationSeconds: Double
  var currentPlayheadSeconds: Double
  @Binding var selectedTimelineEffect: EditorTimelineEffectSelection?
  var onCommitMaskEffectRange: (UUID, Double, Double) -> Void = { _, _, _ in }

  private var sortedMasks: [RecordingProject.VisualMask] {
    project.visualMasks.sorted { lhs, rhs in
      if lhs.startSeconds != rhs.startSeconds {
        return lhs.startSeconds < rhs.startSeconds
      }
      return lhs.endSeconds < rhs.endSeconds
    }
  }

  private var focusedMaskID: UUID? {
    if case .mask(let id) = selectedTimelineEffect {
      return id
    }
    return sortedMasks.first?.id
  }

  private var focusedMask: RecordingProject.VisualMask? {
    guard let focusedMaskID else { return nil }
    return project.visualMasks.first(where: { $0.id == focusedMaskID })
  }

  private var canAddMask: Bool {
    project.visualMasks.count < RecordingProject.TimelineKeyframeSanitize.maxVisualMaskCount
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Button { addMask(.blur) } label: {
          Label(languageStore.localized("Blur"), systemImage: "plus")
            .frame(maxWidth: .infinity)
        }
        .disabled(!canAddMask)
        Button { addMask(.highlight) } label: {
          Label(languageStore.localized("Highlight"), systemImage: "plus")
            .frame(maxWidth: .infinity)
        }
        .disabled(!canAddMask)
      }
      .buttonStyle(.bordered)

      if !canAddMask {
        InspectorEmptyHint(
          text: languageStore.localizedFormat(
            "Masks are limited to %d.",
            RecordingProject.TimelineKeyframeSanitize.maxVisualMaskCount
          )
        )
      }

      if project.visualMasks.isEmpty {
        InspectorEmptyHint(text: "固定矩形のぼかし、または強調マスクを追加できます。")
      } else {
        if sortedMasks.count > 1 {
          maskSegmentList
        }

        if let mask = focusedMask {
          maskDetailEditor(mask: mask)
        }
      }
    }
  }

  private var maskSegmentList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(languageStore.localized("登録済みのマスク"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ScrollView {
        VStack(spacing: 6) {
          ForEach(Array(sortedMasks.enumerated()), id: \.element.id) { index, mask in
            maskSegmentListRow(index: index + 1, mask: mask)
          }
        }
      }
      .frame(maxHeight: EditorLayout.inspectorMaskListMaxHeight)
    }
  }

  private func maskSegmentListRow(index: Int, mask: RecordingProject.VisualMask) -> some View {
    let isSelected = focusedMaskID == mask.id
    return Button {
      selectedTimelineEffect = .mask(mask.id)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: mask.kind == .blur ? "eye.slash" : "highlighter")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isSelected ? EditorPalette.brandStrong : .secondary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 2) {
          Text("\(languageStore.localized(mask.kind.editorTitle)) \(index)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
          Text(maskPeriodSummary(mask))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(EditorPalette.brandStrong)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? EditorPalette.brand.opacity(0.14) : Color.primary.opacity(0.04),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            isSelected ? EditorPalette.brandStrong.opacity(0.55) : Color.primary.opacity(0.08),
            lineWidth: isSelected ? 1.5 : 1
          )
      }
    }
    .buttonStyle(.plain)
  }

  private func maskPeriodSummary(_ mask: RecordingProject.VisualMask) -> String {
    let start = editorFormatTime(mask.startSeconds, fractional: true)
    let end = editorFormatTime(mask.endSeconds, fractional: true)
    let duration = editorFormatTime(max(0, mask.endSeconds - mask.startSeconds), fractional: true)
    return "\(start) – \(end) (\(duration))"
  }

  private func maskDetailEditor(mask: RecordingProject.VisualMask) -> some View {
    InspectorCard(isSelected: selectedTimelineEffect == .mask(mask.id)) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(languageStore.localized(mask.kind.editorTitle))
            .font(.caption.weight(.semibold))
          Spacer()
          Button(role: .destructive) { removeMask(id: mask.id) } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
        }

        InspectorEmptyHint(text: "再生を止めた状態で、プレビュー上の枠をドラッグして位置と大きさを調整します。")

        maskRangeEditor(mask: mask)
        InspectorSlider(
          title: "Opacity",
          value: maskDoubleBinding(id: mask.id, get: \.opacity, set: { $0.opacity = $1 }),
          range: 0...1,
          step: 0.05
        )
      }
    }
  }

  private func addMask(_ kind: RecordingProject.VisualMask.Kind) {
    guard project.visualMasks.count < RecordingProject.TimelineKeyframeSanitize.maxVisualMaskCount else {
      alertCenter.present(
        languageStore.localizedFormat(
          "Masks are limited to %d.",
          RecordingProject.TimelineKeyframeSanitize.maxVisualMaskCount
        )
      )
      return
    }
    guard let range = EditorSegmentRange.playheadBased(
      at: currentPlayheadSeconds,
      preferredDuration: 2,
      totalDuration: durationSeconds,
      minimumDuration: RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds
    ) else {
      alertCenter.present("追加できる範囲がありません")
      return
    }
    let newID = UUID()
    projectStore.applyToCurrent { project in
      project.visualMasks.append(
        RecordingProject.VisualMask(
          id: newID,
          startSeconds: range.start,
          endSeconds: range.end,
          kind: kind
        )
      )
      project.visualMasks = RecordingProject.sanitizedVisualMasks(
        project.visualMasks,
        durationSeconds: durationSeconds
      )
    }
    selectedTimelineEffect = .mask(newID)
  }

  private func removeMask(id: UUID) {
    projectStore.applyToCurrent { project in
      project.visualMasks.removeAll { $0.id == id }
    }
    if case .mask(let selectedID) = selectedTimelineEffect, selectedID == id {
      let nextID = projectStore.current?.visualMasks
        .sorted { $0.startSeconds < $1.startSeconds }
        .first?
        .id
      selectedTimelineEffect = nextID.map { .mask($0) }
    }
  }

  private func updateMask(id: UUID, mutate: @escaping (inout RecordingProject.VisualMask) -> Void) {
    projectStore.applyToCurrent { project in
      guard let index = project.visualMasks.firstIndex(where: { $0.id == id }) else { return }
      mutate(&project.visualMasks[index])
      project.visualMasks = RecordingProject.sanitizedVisualMasks(project.visualMasks, durationSeconds: durationSeconds)
    }
  }

  private func maskDoubleBinding(
    id: UUID,
    get: KeyPath<RecordingProject.VisualMask, Double>,
    set: @escaping (inout RecordingProject.VisualMask, Double) -> Void
  ) -> Binding<Double> {
    Binding(
      get: { project.visualMasks.first(where: { $0.id == id })?[keyPath: get] ?? 0 },
      set: { value in updateMask(id: id) { set(&$0, value) } }
    )
  }

  private func maskRangeEditor(mask: RecordingProject.VisualMask) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(languageStore.localized("Range"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        TextField(
          "Start",
          value: Binding(
            get: { mask.startSeconds },
            set: { commitMaskRange(mask: mask, startSeconds: $0) }
          ),
          format: .number.precision(.fractionLength(2))
        )
        TextField(
          "End",
          value: Binding(
            get: { mask.endSeconds },
            set: { commitMaskRange(mask: mask, endSeconds: $0) }
          ),
          format: .number.precision(.fractionLength(2))
        )
        TextField(
          "Dur",
          value: Binding(
            get: { max(0, mask.endSeconds - mask.startSeconds) },
            set: { commitMaskRange(mask: mask, durationSeconds: $0) }
          ),
          format: .number.precision(.fractionLength(2))
        )
      }
      .textFieldStyle(.roundedBorder)
    }
  }

  private func commitMaskRange(
    mask: RecordingProject.VisualMask,
    startSeconds: Double? = nil,
    endSeconds: Double? = nil,
    durationSeconds proposedDuration: Double? = nil
  ) {
    let range = TimelineEditableRange(
      id: mask.id,
      kind: .mask,
      startSeconds: mask.startSeconds,
      endSeconds: mask.endSeconds,
      minDuration: RecordingProject.TimelineKeyframeSanitize.minHighlightSpanSeconds,
      canTrim: true,
      canMove: true
    )
    let updated: TimelineEditableRange
    if let startSeconds {
      updated = range.trimmingLeading(to: startSeconds, durationSeconds: durationSeconds)
    } else if let endSeconds {
      updated = range.trimmingTrailing(to: endSeconds, durationSeconds: durationSeconds)
    } else if let proposedDuration {
      updated = range.resizingDuration(to: proposedDuration, durationSeconds: durationSeconds)
    } else {
      updated = range.sanitized(durationSeconds: durationSeconds)
    }
    onCommitMaskEffectRange(mask.id, updated.startSeconds, updated.endSeconds)
  }
}

struct CaptionsInspector: View {
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter

  var project: RecordingProject
  var durationSeconds: Double
  var selectedTimelineEffect: EditorTimelineEffectSelection?
  var onCommitCaptionEffectRange: (UUID, Double, Double) -> Void
  var captionGenerator: CaptionGenerator

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Toggle(
        languageStore.localized("Enabled"),
        isOn: Binding(
          get: { project.captionTrack.isEnabled },
          set: { value in updateTrack { $0.isEnabled = value } }
        )
      )

      HStack {
        Button {
          generateCaptions()
        } label: {
          Label(languageStore.localized(captionGenerator.state == .generating ? "Generating" : "Generate"), systemImage: "waveform.and.magnifyingglass")
        }
        .disabled(captionGenerator.state == .generating)
        Button { addCaption() } label: { Label(languageStore.localized("Add"), systemImage: "plus") }
      }
      .buttonStyle(.bordered)

      InspectorSlider(
        title: languageStore.localized("Font"),
        value: Binding(
          get: { project.captionTrack.style.fontPointSize },
          set: { value in updateTrack { $0.style = .init(fontPointSize: value, bottomInsetN: $0.style.bottomInsetN, backgroundOpacity: $0.style.backgroundOpacity) } }
        ),
        range: 12...80,
        step: 1
      )
      InspectorSlider(
        title: languageStore.localized("Bottom inset"),
        value: Binding(
          get: { project.captionTrack.style.bottomInsetN },
          set: { value in updateTrack { $0.style = .init(fontPointSize: $0.style.fontPointSize, bottomInsetN: value, backgroundOpacity: $0.style.backgroundOpacity) } }
        ),
        range: 0...0.3,
        step: 0.01
      )

      if project.captionTrack.segments.isEmpty {
        InspectorEmptyHint(text: "Apple Speech でオンデバイス字幕を生成するか、手動で追加します。")
      } else {
        ForEach(project.captionTrack.segments) { segment in
          InspectorCard(isSelected: selectedTimelineEffect == .caption(segment.id)) {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("\(editorFormatTime(segment.startSeconds, fractional: true)) – \(editorFormatTime(segment.endSeconds, fractional: true))")
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { removeCaption(id: segment.id) } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
              }
              TextField(
                languageStore.localized("Caption"),
                text: Binding(
                  get: { segment.text },
                  set: { text in updateSegment(id: segment.id) { $0.text = text } }
                )
              )
              captionRangeEditor(segment: segment)
            }
          }
        }
      }
    }
    .onChange(of: captionGenerator.state) { _, state in
      if case .failed(let message) = state {
        alertCenter.present(message)
      }
    }
  }

  private func generateCaptions() {
    Task {
      if let result = await captionGenerator.generateFromMedia(url: project.mediaURL) {
        projectStore.applyToCurrent { project in
          project.captionTrack = RecordingProject.CaptionTrack(
            isEnabled: true,
            transcript: result.transcript,
            languageIdentifier: "ja-JP",
            segments: result.overlays.map {
              RecordingProject.CaptionTrack.Segment(
                id: $0.id,
                startSeconds: $0.startSeconds,
                endSeconds: $0.endSeconds,
                text: $0.text
              )
            },
            style: project.captionTrack.style
          )
        }
      }
    }
  }

  private func addCaption() {
    let rawStart = project.captionTrack.segments.last?.endSeconds ?? 0
    guard let range = EditorSegmentRange.appendBased(
      after: rawStart,
      preferredDuration: 2,
      totalDuration: durationSeconds,
      minimumDuration: 0.05
    ) else {
      alertCenter.present("追加できる範囲がありません")
      return
    }
    updateTrack {
      $0.isEnabled = true
      $0.segments.append(.init(startSeconds: range.start, endSeconds: range.end, text: "New caption"))
    }
  }

  private func removeCaption(id: UUID) {
    updateTrack { $0.segments.removeAll { $0.id == id } }
  }

  private func updateSegment(id: UUID, mutate: @escaping (inout RecordingProject.CaptionTrack.Segment) -> Void) {
    updateTrack { track in
      guard let index = track.segments.firstIndex(where: { $0.id == id }) else { return }
      mutate(&track.segments[index])
      track = RecordingProject.CaptionTrack(
        isEnabled: track.isEnabled,
        transcript: track.transcript,
        languageIdentifier: track.languageIdentifier,
        segments: track.segments,
        style: track.style
      )
    }
  }

  private func updateTrack(_ mutate: @escaping (inout RecordingProject.CaptionTrack) -> Void) {
    projectStore.applyToCurrent { project in
      var track = project.captionTrack
      mutate(&track)
      project.captionTrack = track
    }
  }

  private func captionRangeEditor(segment: RecordingProject.CaptionTrack.Segment) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(languageStore.localized("Range"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        TextField(
          "Start",
          value: Binding(
            get: { segment.startSeconds },
            set: { commitCaptionRange(segment: segment, startSeconds: $0) }
          ),
          format: .number.precision(.fractionLength(2))
        )
        TextField(
          "End",
          value: Binding(
            get: { segment.endSeconds },
            set: { commitCaptionRange(segment: segment, endSeconds: $0) }
          ),
          format: .number.precision(.fractionLength(2))
        )
        TextField(
          "Dur",
          value: Binding(
            get: { max(0, segment.endSeconds - segment.startSeconds) },
            set: { commitCaptionRange(segment: segment, durationSeconds: $0) }
          ),
          format: .number.precision(.fractionLength(2))
        )
      }
      .textFieldStyle(.roundedBorder)
    }
  }

  private func commitCaptionRange(
    segment: RecordingProject.CaptionTrack.Segment,
    startSeconds: Double? = nil,
    endSeconds: Double? = nil,
    durationSeconds proposedDuration: Double? = nil
  ) {
    let range = TimelineEditableRange(
      id: segment.id,
      kind: .caption,
      startSeconds: segment.startSeconds,
      endSeconds: segment.endSeconds,
      minDuration: 0.05,
      canTrim: true,
      canMove: true
    )
    let updated: TimelineEditableRange
    if let startSeconds {
      updated = range.trimmingLeading(to: startSeconds, durationSeconds: durationSeconds)
    } else if let endSeconds {
      updated = range.trimmingTrailing(to: endSeconds, durationSeconds: durationSeconds)
    } else if let proposedDuration {
      updated = range.resizingDuration(to: proposedDuration, durationSeconds: durationSeconds)
    } else {
      updated = range.sanitized(durationSeconds: durationSeconds)
    }
    onCommitCaptionEffectRange(segment.id, updated.startSeconds, updated.endSeconds)
  }
}

struct CameraInspector: View {
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  var project: RecordingProject
  var durationSeconds: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if project.secondaryRecording == nil {
        InspectorEmptyHint(text: "録画時にカメラを有効にすると、ここで PiP / 全画面 / 非表示を調整できます。")
      }

      Button {
        ensureSegment()
      } label: {
        Label(languageStore.localized(project.cameraLayoutSegments.isEmpty ? "Add camera layout" : "Add segment"), systemImage: "plus")
      }
      .buttonStyle(.bordered)
      .disabled(project.secondaryRecording == nil)

      ForEach(project.cameraLayoutSegments) { segment in
        InspectorCard {
          VStack(alignment: .leading, spacing: 10) {
            Picker(languageStore.localized("Layout"), selection: cameraLayoutBinding(id: segment.id)) {
              ForEach(RecordingProject.CameraLayoutSegment.Layout.allCases, id: \.self) { layout in
                Text(languageStore.localized(layout.editorTitle)).tag(layout)
              }
            }
            rangeEditor(
              title: languageStore.localized("Range"),
              start: segment.startSeconds,
              end: segment.endSeconds,
              update: { start, end in updateSegment(id: segment.id) { $0.startSeconds = start; $0.endSeconds = end } }
            )
            InspectorSlider(title: "X", value: cameraDoubleBinding(id: segment.id, get: \.originXN, set: { $0.originXN = $1 }), range: 0...1, step: 0.01)
            InspectorSlider(title: "Y", value: cameraDoubleBinding(id: segment.id, get: \.originYN, set: { $0.originYN = $1 }), range: 0...1, step: 0.01)
            InspectorSlider(title: languageStore.localized("Width"), value: cameraDoubleBinding(id: segment.id, get: \.widthN, set: { $0.widthN = $1 }), range: 0.05...1, step: 0.01)
            InspectorSlider(title: languageStore.localized("Corner"), value: cameraDoubleBinding(id: segment.id, get: \.cornerRadiusPts, set: { $0.cornerRadiusPts = $1 }), range: 0...80, step: 1)
            Toggle(languageStore.localized("Mirror"), isOn: cameraBoolBinding(id: segment.id, get: \.isMirrored, set: { $0.isMirrored = $1 }))
          }
        }
      }
    }
  }

  private func ensureSegment() {
    let rawStart = project.cameraLayoutSegments.last?.endSeconds ?? 0
    guard let range = EditorSegmentRange.appendBased(
      after: rawStart,
      preferredDuration: 3,
      totalDuration: durationSeconds,
      minimumDuration: 0.1
    ) else {
      alertCenter.present("追加できる範囲がありません")
      return
    }
    projectStore.applyToCurrent { project in
      project.cameraLayoutSegments.append(.init(startSeconds: range.start, endSeconds: range.end))
      project.cameraLayoutSegments = RecordingProject.sanitizedCameraLayoutSegments(
        project.cameraLayoutSegments,
        durationSeconds: durationSeconds
      )
      syncSecondaryAttachment(project: &project)
    }
  }

  private func updateSegment(id: UUID, mutate: @escaping (inout RecordingProject.CameraLayoutSegment) -> Void) {
    projectStore.applyToCurrent { project in
      guard let index = project.cameraLayoutSegments.firstIndex(where: { $0.id == id }) else { return }
      mutate(&project.cameraLayoutSegments[index])
      project.cameraLayoutSegments = RecordingProject.sanitizedCameraLayoutSegments(
        project.cameraLayoutSegments,
        durationSeconds: durationSeconds
      )
      syncSecondaryAttachment(project: &project)
    }
  }

  private func syncSecondaryAttachment(project: inout RecordingProject) {
    guard var secondary = project.secondaryRecording,
      let active = project.cameraLayoutSegments.first(where: { $0.layout == .pip || $0.layout == .fullscreen })
    else { return }
    secondary.originXN = active.originXN
    secondary.originYN = active.originYN
    secondary.widthN = active.layout == .fullscreen ? 1 : active.widthN
    secondary.heightN = active.layout == .fullscreen ? 1 : active.heightN
    secondary.cornerRadiusPts = active.layout == .fullscreen ? 0 : active.cornerRadiusPts
    project.secondaryRecording = secondary.clampedForExport()
  }

  private func cameraLayoutBinding(id: UUID) -> Binding<RecordingProject.CameraLayoutSegment.Layout> {
    Binding(
      get: { project.cameraLayoutSegments.first(where: { $0.id == id })?.layout ?? .pip },
      set: { value in updateSegment(id: id) { $0.layout = value } }
    )
  }

  private func cameraDoubleBinding(
    id: UUID,
    get: KeyPath<RecordingProject.CameraLayoutSegment, Double>,
    set: @escaping (inout RecordingProject.CameraLayoutSegment, Double) -> Void
  ) -> Binding<Double> {
    Binding(
      get: { project.cameraLayoutSegments.first(where: { $0.id == id })?[keyPath: get] ?? 0 },
      set: { value in updateSegment(id: id) { set(&$0, value) } }
    )
  }

  private func cameraBoolBinding(
    id: UUID,
    get: KeyPath<RecordingProject.CameraLayoutSegment, Bool>,
    set: @escaping (inout RecordingProject.CameraLayoutSegment, Bool) -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { project.cameraLayoutSegments.first(where: { $0.id == id })?[keyPath: get] ?? false },
      set: { value in updateSegment(id: id) { set(&$0, value) } }
    )
  }
}

struct AudioInspector: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppLanguageStore.self) private var languageStore
  var project: RecordingProject
  var selectedTimelineEffect: EditorTimelineEffectSelection?

  private var selectedAudioSegment: RecordingProject.AudioTimelineSegment? {
    guard case .audio(let id) = selectedTimelineEffect else { return nil }
    return project.audioTimelineSegments.first(where: { $0.id == id })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let selectedAudioSegment {
        InspectorCard {
          VStack(alignment: .leading, spacing: 10) {
            Text(languageStore.localizedFormat(
              "Timeline range %@ – %@",
              editorFormatTime(selectedAudioSegment.startSeconds),
              editorFormatTime(selectedAudioSegment.endSeconds)
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }
      }

      audioTrackControl(title: languageStore.localized("Microphone"), keyPath: \.microphone)
      audioTrackControl(title: languageStore.localized("System audio"), keyPath: \.system)
      audioTrackControl(title: languageStore.localized("Background music"), keyPath: \.backgroundMusic)

      Button {
        chooseBackgroundMusic()
      } label: {
        Label(project.audioTrackSettings.backgroundMusicURL?.lastPathComponent ?? languageStore.localized("Choose music"), systemImage: "music.note")
          .lineLimit(1)
      }
      .buttonStyle(.bordered)
    }
  }

  private func audioTrackControl(
    title: String,
    keyPath: WritableKeyPath<RecordingProject.AudioTrackSettings, RecordingProject.AudioTrackSettings.Track>
  ) -> some View {
    InspectorCard {
      VStack(alignment: .leading, spacing: 10) {
        Toggle(
          title,
          isOn: Binding(
            get: { project.audioTrackSettings[keyPath: keyPath].isEnabled },
            set: { value in updateSettings { $0[keyPath: keyPath].isEnabled = value } }
          )
        )
        InspectorSlider(
          title: languageStore.localized("Volume"),
          value: Binding(
            get: { project.audioTrackSettings[keyPath: keyPath].volume },
            set: { value in updateSettings { $0[keyPath: keyPath].volume = value } }
          ),
          range: 0...2,
          step: 0.05
        )
      }
    }
  }

  private func chooseBackgroundMusic() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      updateSettings {
        $0.backgroundMusicURL = url
        $0.backgroundMusic.isEnabled = true
      }
    }
  }

  private func updateSettings(_ mutate: @escaping (inout RecordingProject.AudioTrackSettings) -> Void) {
    projectStore.applyToCurrent { project in
      var settings = project.audioTrackSettings
      mutate(&settings)
      project.audioTrackSettings = settings
    }
  }
}

struct ExportInspector: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppLanguageStore.self) private var languageStore
  var project: RecordingProject
  var isExporting: Bool
  var exportAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker(
        languageStore.localized("Preset"),
        selection: Binding(
          get: { project.exportPreset },
          set: { value in projectStore.applyToCurrent { $0.exportPreset = value } }
        )
      ) {
        ForEach(ExportPreset.all) { preset in
          Text(preset.title).tag(preset.id)
        }
      }
      .pickerStyle(.menu)

      Picker(
        languageStore.localized("Aspect"),
        selection: Binding(
          get: { project.outputAspectRatio },
          set: { value in projectStore.applyToCurrent { $0.outputAspectRatio = value } }
        )
      ) {
        ForEach(AspectRatioPreset.allCases) { preset in
          Text(preset.title).tag(preset)
        }
      }
      .pickerStyle(.segmented)

      Button(action: exportAction) {
        Label(languageStore.localized(isExporting ? "Exporting" : "Save MP4"), systemImage: "square.and.arrow.down")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(isExporting)
    }
  }
}

struct QuickSharePanel: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  @Environment(AppLanguageStore.self) private var languageStore
  @State private var exporter = Exporter()

  var project: RecordingProject
  var onEdit: () -> Void
  var onDiscard: () -> Void

  @State private var lastOutputURL: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 10) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(EditorPalette.brandStrong)
        VStack(alignment: .leading, spacing: 2) {
          Text(languageStore.localized("Recording ready"))
            .font(.title3.weight(.semibold))
          Text(
            languageStore.localizedProjectDisplayTitle(
              storedTitle: project.title,
              createdAt: project.createdAt
            )
          )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      HStack(spacing: 10) {
        Button(action: onEdit) {
          Label(languageStore.localized("Edit"), systemImage: "slider.horizontal.3")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button {
          saveMP4()
        } label: {
          Label(languageStore.localized("Save MP4"), systemImage: "square.and.arrow.down")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isExporting)
      }

      HStack(spacing: 10) {
        Button {
          copyMP4()
        } label: {
          Label(languageStore.localized("Copy"), systemImage: "doc.on.clipboard")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isExporting)

        Button(role: .destructive) {
          projectStore.dismissQuickShare()
          onDiscard()
        } label: {
          Label(languageStore.localized("Discard"), systemImage: "trash")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isExporting)
      }

      if isExporting {
        ProgressView(value: exporter.progress)
      }

      switch exporter.state {
      case .idle:
        EmptyView()
      case .exporting:
        Text(languageStore.localized("Exporting..."))
          .font(.caption)
          .foregroundStyle(.secondary)
      case .finished(let url):
        Text(languageStore.localizedFormat("Done: %@", url.lastPathComponent))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      case .failed(let message):
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .padding(22)
    .onChange(of: exporter.state) { _, state in
      if case .failed(let message) = state {
        alertCenter.present(message)
      }
    }
  }

  private var isExporting: Bool {
    if case .exporting = exporter.state { return true }
    return false
  }

  private func saveMP4() {
    ExportSavePanelPresenter.chooseDestination(
      allowedContentTypes: [.mpeg4Movie],
      defaultFilename: "\(safeFilename(project.title)).mp4"
    ) { url in
      lastOutputURL = url
      exporter.export(project: projectStore.current ?? project, to: url)
    }
  }

  private func copyMP4() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(safeFilename(project.title))-\(UUID().uuidString.prefix(8)).mp4")
    lastOutputURL = url
    exporter.export(project: projectStore.current ?? project, to: url, copyToClipboard: true)
  }

  private func safeFilename(_ raw: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let cleaned = raw
      .components(separatedBy: invalid)
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "ArcShot Export" : cleaned
  }
}

struct InspectorCard<Content: View>: View {
  var isSelected: Bool
  private var content: Content

  init(isSelected: Bool = false, @ViewBuilder content: () -> Content) {
    self.isSelected = isSelected
    self.content = content()
  }

  var body: some View {
    content
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? EditorPalette.brand.opacity(0.13) : Color.primary.opacity(0.045),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            isSelected ? EditorPalette.brandStrong.opacity(0.62) : Color.primary.opacity(0.08),
            lineWidth: isSelected ? 1.5 : 1
          )
      }
  }
}

struct InspectorEmptyHint: View {
  @Environment(AppLanguageStore.self) private var languageStore
  var text: String

  var body: some View {
    Text(languageStore.localized(text))
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct InspectorSlider: View {
  @Environment(AppLanguageStore.self) private var languageStore
  var title: String
  @Binding var value: Double
  var range: ClosedRange<Double>
  var step: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(languageStore.localized(title))
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Spacer()
        Text(value, format: .number.precision(.fractionLength(step < 1 ? 2 : 0)))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(minWidth: 44, alignment: .trailing)
      }
      Slider(value: $value, in: range, step: step)
        .controlSize(.small)
    }
  }
}

struct InspectorMetricGrid: View {
  var items: [(String, String)]

  var body: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
      ForEach(items, id: \.0) { item in
        VStack(alignment: .leading, spacing: 4) {
          Text(item.0)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(item.1)
            .font(.system(.callout, design: .monospaced).weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
  }
}

struct EditorCommandMenu: View {
  @Environment(AppLanguageStore.self) private var languageStore

  enum CommandKind: String, CaseIterable, Identifiable {
    case addZoom
    case addAutoZooms
    case addBlurMask
    case addHighlightMask
    case addCaption
    case toggleCursor
    case export

    var id: String { rawValue }

    var title: String {
      switch self {
      case .addZoom: return "Add Zoom"
      case .addAutoZooms: return "Add Auto Zooms"
      case .addBlurMask: return "Add Blur Mask"
      case .addHighlightMask: return "Add Highlight Mask"
      case .addCaption: return "Add Caption"
      case .toggleCursor: return "Toggle Cursor"
      case .export: return "Save MP4"
      }
    }

    var subtitle: String {
      switch self {
      case .addZoom: return "現在位置に手動ズームを作成"
      case .addAutoZooms: return "クリックとカーソル滞留から候補を作成"
      case .addBlurMask: return "画面の一部をぼかす"
      case .addHighlightMask: return "画面の一部を強調"
      case .addCaption: return "手動字幕セグメントを追加"
      case .toggleCursor: return "カーソル表示を切り替え"
      case .export: return "MP4として書き出し"
      }
    }

    var icon: String {
      switch self {
      case .addZoom: return "plus.magnifyingglass"
      case .addAutoZooms: return "wand.and.stars"
      case .addBlurMask: return "app.dashed"
      case .addHighlightMask: return "scope"
      case .addCaption: return "captions.bubble"
      case .toggleCursor: return "cursorarrow.motionlines"
      case .export: return "square.and.arrow.down"
      }
    }
  }

  var project: RecordingProject
  var isExporting: Bool
  var dismiss: () -> Void
  var perform: (CommandKind, RecordingProject) -> Void

  @State private var query = ""

  private var commands: [CommandKind] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return CommandKind.allCases }
    return CommandKind.allCases.filter {
      $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "command")
          .foregroundStyle(.secondary)
        TextField(languageStore.localized("Search commands"), text: $query)
          .textFieldStyle(.plain)
      }
      .padding(14)
      .background(Color.primary.opacity(0.055))

      List(commands) { command in
        Button {
          dismiss()
          perform(command, project)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: command.icon)
              .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
              Text(languageStore.localized(command.title))
                .font(.callout.weight(.semibold))
              Text(languageStore.localized(command.subtitle))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(command == .export && isExporting)
      }
      .listStyle(.inset)
    }
  }
}

struct BackgroundInspector: View {
  @Environment(AppLanguageStore.self) private var languageStore

  var project: RecordingProject
  @Binding var backgroundMode: EditorBackgroundMode
  var updateVisuals: ((inout RecordingProject.ExportVisualSettings) -> Void) -> Void

  private let wallpaperPresets: [BackgroundPreset] = [
    .init(name: "macOS", colors: ["#D8ECFF", "#2F72DD"]),
    .init(name: "Spring", colors: ["#EEF2F3", "#8FCAC4"]),
    .init(name: "Sunset", colors: ["#F7B267", "#6B4EFF"]),
    .init(name: "Radial", colors: ["#E8E0FF", "#2F55D4"]),
  ]

  private let gradientPresets: [BackgroundPreset] = [
    .init(name: "Ocean", colors: ["#3F37C9", "#8C87DF"]),
    .init(name: "Mint", colors: ["#EEF2F3", "#8FCAC4"]),
    .init(name: "Peach", colors: ["#FFE0CF", "#FF7A59"]),
    .init(name: "Slate", colors: ["#202532", "#5B677A"]),
    .init(name: "Sky", colors: ["#DDF4FF", "#4DA3FF"]),
    .init(name: "Rose", colors: ["#FFE5EC", "#F06292"]),
    .init(name: "Lime", colors: ["#F3FFD7", "#85C872"]),
    .init(name: "Violet", colors: ["#EEE7FF", "#7A5CFF"]),
    .init(name: "Sand", colors: ["#FFF2D0", "#D7A84F"]),
    .init(name: "Aqua", colors: ["#DDFCF8", "#2EAAA1"]),
    .init(name: "Coral", colors: ["#FFD6C8", "#FF6B6B"]),
    .init(name: "Mono", colors: ["#F2F4F8", "#B8C0CC"]),
  ]

  private let colorPresets = [
    "#EEF2F3", "#8FCAC4", "#3F37C9", "#8C87DF", "#202532", "#5B677A",
    "#FFE0CF", "#FF7A59", "#DDF4FF", "#4DA3FF", "#F3FFD7", "#85C872",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      BackgroundModeSelector(selection: $backgroundMode)

      modeContent

      VStack(spacing: 0) {
        BackgroundInspectorSlider(
          title: languageStore.localized("Background blur"),
          value: visualBinding(get: \.backgroundBlur, set: { $0.backgroundBlur = $1 }),
          range: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.backgroundBlurMaxPts,
          resetValue: RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultBackgroundBlurPts
        )
        BackgroundInspectorSlider(
          title: languageStore.localized("Padding"),
          value: visualBinding(get: \.backgroundPadding, set: { $0.backgroundPadding = $1 }),
          range: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.backgroundPaddingMaxPts,
          resetValue: RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultBackgroundPaddingPts
        )
        BackgroundInspectorSlider(
          title: languageStore.localized("Rounded corners"),
          value: visualBinding(get: \.contentCornerRadius, set: { $0.contentCornerRadius = $1 }),
          range: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.contentCornerRadiusMaxPts,
          resetValue: RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultCornerRadiusPts
        )
        BackgroundInspectorSlider(
          title: languageStore.localized("Inset"),
          value: visualBinding(get: \.contentInset, set: { $0.contentInset = $1 }),
          range: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.contentInsetMaxPts,
          resetValue: RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultContentInsetPts
        )
        BackgroundInspectorSlider(
          title: languageStore.localized("Shadow"),
          value: visualBinding(get: \.shadowRadius, set: { $0.shadowRadius = $1 }),
          range: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.shadowRadiusMaxPts,
          resetValue: RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultShadowRadiusPts
        )
      }
      .padding(.top, 2)
    }
  }

  @ViewBuilder
  private var modeContent: some View {
    switch backgroundMode {
    case .wallpaper:
      VStack(alignment: .leading, spacing: 12) {
        Text(languageStore.localized("Wallpaper"))
          .font(.caption.weight(.semibold))
        presetGrid(wallpaperPresets)
      }
    case .gradient:
      VStack(alignment: .leading, spacing: 12) {
        Text(languageStore.localized("Background Gradient"))
          .font(.caption.weight(.semibold))
        HStack(spacing: 10) {
          BackgroundColorToken(hex: project.exportVisualSettings.backgroundColorHex)
          Text(project.exportVisualSettings.backgroundColorHex)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
          BackgroundColorToken(hex: project.exportVisualSettings.gradientEndColorHex)
          Text(project.exportVisualSettings.gradientEndColorHex)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        presetGrid(gradientPresets)
      }
    case .color:
      VStack(alignment: .leading, spacing: 12) {
        Text(languageStore.localized("Background Color"))
          .font(.caption.weight(.semibold))
        HStack(spacing: 10) {
          ColorPicker(
            "",
            selection: Binding(
              get: { Color(nsColor: EditorHexColor.nsColor(rgbHex: project.exportVisualSettings.backgroundColorHex)) },
              set: { color in
                applyColor(EditorHexColor.rgbHexString(from: NSColor(color)))
              }
            ),
            supportsOpacity: false
          )
          .labelsHidden()
          Text(project.exportVisualSettings.backgroundColorHex)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        colorGrid
      }
    case .image:
      VStack(alignment: .leading, spacing: 12) {
        Text(languageStore.localized("Background Image"))
          .font(.caption.weight(.semibold))
        VStack(spacing: 8) {
          Image(systemName: "photo")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.secondary)
          Text(languageStore.localized("Image backgrounds are not connected yet."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
      }
    }
  }

  private func presetGrid(_ presets: [BackgroundPreset]) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
      ForEach(presets) { preset in
        Button {
          applyPreset(preset)
        } label: {
          BackgroundPresetSwatch(preset: preset, isSelected: isSelectedPreset(preset))
        }
        .buttonStyle(.plain)
        .help(preset.name)
      }
    }
  }

  private var colorGrid: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
      ForEach(colorPresets, id: \.self) { hex in
        Button {
          applyColor(hex)
        } label: {
          BackgroundColorToken(hex: hex, isSelected: project.exportVisualSettings.backgroundKind == .solid && project.exportVisualSettings.backgroundColorHex == hex)
        }
        .buttonStyle(.plain)
        .help(hex)
      }
    }
  }

  private func applyPreset(_ preset: BackgroundPreset) {
    updateVisuals {
      $0.backgroundKind = .linearGradientVertical
      $0.backgroundColorHex = preset.colors[0]
      $0.gradientEndColorHex = preset.colors[1]
      $0.backgroundGradientStyle = backgroundMode == .wallpaper ? .wallpaper : .vertical
    }
  }

  private func applyColor(_ hex: String) {
    updateVisuals {
      $0.backgroundKind = .solid
      $0.backgroundColorHex = hex
    }
  }

  private func isSelectedPreset(_ preset: BackgroundPreset) -> Bool {
    project.exportVisualSettings.backgroundKind == .linearGradientVertical
      && project.exportVisualSettings.backgroundColorHex == preset.colors[0]
      && project.exportVisualSettings.gradientEndColorHex == preset.colors[1]
  }

  private func visualBinding(
    get: KeyPath<RecordingProject.ExportVisualSettings, Double>,
    set: @escaping (inout RecordingProject.ExportVisualSettings, Double) -> Void
  ) -> Binding<Double> {
    Binding(
      get: { project.exportVisualSettings[keyPath: get] },
      set: { newValue in
        updateVisuals { visuals in
          set(&visuals, newValue)
        }
      }
    )
  }
}

struct BackgroundPreset: Identifiable {
  var name: String
  var colors: [String]

  var id: String { name }
}

struct BackgroundModeSelector: View {
  @Environment(AppLanguageStore.self) private var languageStore

  @Binding var selection: EditorBackgroundMode

  var body: some View {
    HStack(spacing: 4) {
      ForEach(EditorBackgroundMode.allCases) { mode in
        Button {
          selection = mode
        } label: {
          Text(languageStore.localized(mode.title))
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == mode ? Color.primary : Color.secondary)
        .background(
          selection == mode ? Color.primary.opacity(0.10) : Color.clear,
          in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(selection == mode ? EditorPalette.brandStrong.opacity(0.45) : Color.clear, lineWidth: 1)
        }
      }
    }
  }
}

struct BackgroundPresetSwatch: View {
  var preset: BackgroundPreset
  var isSelected: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .fill(
        LinearGradient(
          colors: preset.colors.map { Color(nsColor: EditorHexColor.nsColor(rgbHex: $0)) },
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .frame(width: 34, height: 30)
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(isSelected ? EditorPalette.brandStrong : Color.white.opacity(0.28), lineWidth: isSelected ? 2 : 1)
      }
  }
}

struct BackgroundColorToken: View {
  var hex: String
  var isSelected: Bool = false

  var body: some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .fill(Color(nsColor: EditorHexColor.nsColor(rgbHex: hex)))
      .frame(width: 34, height: 30)
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(isSelected ? EditorPalette.brandStrong : Color.white.opacity(0.28), lineWidth: isSelected ? 2 : 1)
      }
  }
}

struct BackgroundInspectorSlider: View {
  @Environment(AppLanguageStore.self) private var languageStore
  var title: String
  @Binding var value: Double
  var range: ClosedRange<Double>
  var resetValue: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Spacer()
        Text(value, format: .number.precision(.fractionLength(0)))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(width: 34, alignment: .trailing)
        Button(languageStore.localized("Reset")) {
          value = resetValue
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary.opacity(0.8))
        .disabled(abs(value - resetValue) < 0.001)
      }
      Slider(value: $value, in: range, step: 1)
        .controlSize(.small)
    }
    .padding(.vertical, 12)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.07))
        .frame(height: 1)
    }
  }
}

// MARK: - Shared Helpers

func rangeEditor(
  title: String,
  start: Double,
  end: Double,
  update: @escaping @MainActor @Sendable (Double, Double) -> Void
) -> some View {
  VStack(alignment: .leading, spacing: 6) {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
    HStack(spacing: 8) {
      TextField(
        "Start",
        value: Binding(
          get: { start },
          set: { newValue in
            Task { @MainActor in
              update(max(0, newValue), max(end, newValue))
            }
          }
        ),
        format: .number.precision(.fractionLength(2))
      )
      TextField(
        "End",
        value: Binding(
          get: { end },
          set: { newValue in
            Task { @MainActor in
              update(min(start, newValue), max(start, newValue))
            }
          }
        ),
        format: .number.precision(.fractionLength(2))
      )
    }
    .textFieldStyle(.roundedBorder)
  }
}

extension RecordingProject.ZoomSegment.Mode {
  var editorTitle: String {
    switch self {
    case .auto: return "Auto"
    case .manual: return "Manual"
    case .instant: return "Instant"
    }
  }
}

extension RecordingProject.VisualMask.Kind {
  var editorTitle: String {
    switch self {
    case .blur: return "Blur"
    case .highlight: return "Highlight"
    }
  }
}

extension RecordingProject.CameraLayoutSegment.Layout {
  var editorTitle: String {
    switch self {
    case .hidden: return "Hidden"
    case .pip: return "PiP"
    case .fullscreen: return "Fullscreen"
    }
  }
}
