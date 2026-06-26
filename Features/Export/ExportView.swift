import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  @Environment(AppLanguageStore.self) private var languageStore
  @State private var exporter = Exporter()

  @State private var selectedPresetID: RecordingProject.ExportPresetID = .matchSource60
  @State private var selectedAspectRatio: AspectRatioPreset = .sixteenNine
  @State private var selectedStylePreset: RecordingProject.StylePresetID = .cursorFocus
  @State private var introFadeSeconds: Double = 0
  @State private var outroFadeSeconds: Double = 0
  @State private var softZoomScale: Double = RecordingProject.StyleSettingsDefaults.softZoomScale
  @State private var stageStyle: RecordingProject.ExportVisualSettings.StageStyle = .none
  @State private var backgroundKind: RecordingProject.ExportVisualSettings.BackgroundKind = .solid
  @State private var backgroundGradientStyle: RecordingProject.ExportVisualSettings.BackgroundGradientStyle = .vertical
  @State private var backgroundHex: String =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageBackgroundFallbackHex
  @State private var gradientEndHex: String =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageGradientEndFallbackHex
  @State private var backgroundBlur: Double =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultBackgroundBlurPts
  @State private var backgroundPadding: Double =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultBackgroundPaddingPts
  @State private var contentCornerRadius: Double =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultCornerRadiusPts
  @State private var shadowOpacity: Double =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultShadowOpacity
  @State private var shadowRadius: Double =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultShadowRadiusPts
  @State private var shadowYOffset: Double =
    RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.defaultShadowYOffsetPts
  @State private var enabledStageOnDisplayCapture: Bool = false
  @State private var deviceFramePreset: RecordingProject.ExportVisualSettings.DeviceFramePreset = .none
  @State private var lastExportOutputURL: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: AppUIMetrics.contentSpacing) {
      Text("書き出し")
        .font(.largeTitle.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      if let project = projectStore.current {
        GroupBox("プリセット") {
          VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
            Picker("Preset", selection: $selectedPresetID) {
              ForEach(ExportPreset.all) { preset in
                Text(preset.title).tag(preset.id)
              }
            }
            .labelsHidden()
            .onChange(of: selectedPresetID) { _, newValue in
              var updated = project
              updated.exportPreset = newValue
              projectStore.setCurrent(updated)
              projectStore.saveCurrent()
            }

            Picker("アスペクト比", selection: $selectedAspectRatio) {
              ForEach(AspectRatioPreset.allCases) { ratio in
                Text(ratio.title).tag(ratio)
              }
            }
            .onChange(of: selectedAspectRatio) { _, newValue in
              var updated = project
              updated.outputAspectRatio = newValue
              projectStore.setCurrent(updated)
              projectStore.saveCurrent()
            }
          }
          .padding(.vertical, 6)
        }

        GroupBox("ステージ／フレーミング") {
          VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
            Picker("ステージスタイル", selection: $stageStyle) {
              Text("なし（全面）").tag(RecordingProject.ExportVisualSettings.StageStyle.none)
              Text("背景に浮かせる").tag(RecordingProject.ExportVisualSettings.StageStyle.roundedCard)
            }
            .onChange(of: stageStyle) { _, _ in persistExportVisual(project: project) }

            Picker("背景", selection: $backgroundKind) {
              Text("単色").tag(RecordingProject.ExportVisualSettings.BackgroundKind.solid)
              Text("グラデーション（上→下）").tag(RecordingProject.ExportVisualSettings.BackgroundKind.linearGradientVertical)
            }
            .onChange(of: backgroundKind) { _, _ in persistExportVisual(project: project) }

            HStack(alignment: .firstTextBaseline) {
              Text("上／単色側")
              ColorPicker(
                "",
                selection: backgroundColorBinding,
                supportsOpacity: false
              )
              .labelsHidden()
            }
            HStack(alignment: .firstTextBaseline) {
              Text("グラデーション終端側")
              ColorPicker(
                "",
                selection: gradientEndColorBinding,
                supportsOpacity: false
              )
              .labelsHidden()
            }
            .disabled(backgroundKind != .linearGradientVertical)

            HStack {
              Text("背景ぼかし")
              Slider(
                value: $backgroundBlur,
                in: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.backgroundBlurMaxPts,
                step: 1
              )
              Text(backgroundBlur, format: .number.precision(.fractionLength(0)))
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
            }
            .onChange(of: backgroundBlur) { _, _ in persistExportVisual(project: project) }

            HStack {
              Text("外側余白")
              Slider(
                value: $backgroundPadding,
                in: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.backgroundPaddingMaxPts,
                step: 1
              )
              Text(backgroundPadding, format: .number.precision(.fractionLength(0)))
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
            }
            .onChange(of: backgroundPadding) { _, _ in persistExportVisual(project: project) }

            HStack {
              Text("角の丸み")
              Slider(
                value: $contentCornerRadius,
                in: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.contentCornerRadiusMaxPts,
                step: 1
              )
              Text(contentCornerRadius, format: .number.precision(.fractionLength(0)))
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
            }
            .onChange(of: contentCornerRadius) { _, _ in persistExportVisual(project: project) }

            HStack {
              Text("影の濃さ")
              Slider(value: $shadowOpacity, in: 0...1, step: 0.02)
              Text(shadowOpacity, format: .number.precision(.fractionLength(2)))
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
            }
            .onChange(of: shadowOpacity) { _, _ in persistExportVisual(project: project) }

            HStack {
              Text("影のぼかし")
              Slider(
                value: $shadowRadius,
                in: 0...RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.shadowRadiusMaxPts,
                step: 1
              )
              Text(shadowRadius, format: .number.precision(.fractionLength(0)))
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
            }
            .onChange(of: shadowRadius) { _, _ in persistExportVisual(project: project) }

            HStack {
              Text("影の縦ズレ")
              Slider(
                value: $shadowYOffset,
                in: exportShadowYSliderRange,
                step: 1
              )
              Text(shadowYOffset, format: .number.precision(.fractionLength(0)))
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
            }
            .onChange(of: shadowYOffset) { _, _ in persistExportVisual(project: project) }

            if project.source.kind == .display || project.source.kind == .area {
              Toggle("全画面収録でもステージを使う", isOn: $enabledStageOnDisplayCapture)
                .onChange(of: enabledStageOnDisplayCapture) { _, _ in persistExportVisual(project: project) }
            }

            Picker("デバイス枠", selection: $deviceFramePreset) {
              Text("なし").tag(RecordingProject.ExportVisualSettings.DeviceFramePreset.none)
              Text("ノートパソコン風のアウトライン").tag(RecordingProject.ExportVisualSettings.DeviceFramePreset.laptopOutline)
            }
            .onChange(of: deviceFramePreset) { _, _ in persistExportVisual(project: project) }

            Text("収録映像を背景の上に配置し、角丸と影で浮いて見えるようにします。全画面は上のトグルがオフならベタ貼りの見た目のままです。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
        }

        GroupBox("スタイル") {
          Picker("スタイル", selection: $selectedStylePreset) {
            ForEach(RecordingProject.StylePresetID.allCases) { preset in
              Text(preset.title).tag(preset)
            }
          }
          .labelsHidden()
          .padding(.vertical, 6)
          .onChange(of: selectedStylePreset) { _, newValue in
            var updated = project
            updated.stylePreset = newValue
            projectStore.setCurrent(updated)
            projectStore.saveCurrent()
          }

          VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
            HStack {
              Text("イントロのフェード")
              Slider(
                value: $introFadeSeconds,
                in: 0...RecordingProject.StyleSettingsDefaults.introFadeMaxSeconds,
                step: 0.05
              )
              Text(introFadeSeconds, format: .number.precision(.fractionLength(2)))
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
            }
            HStack {
              Text("アウトロのフェード")
              Slider(
                value: $outroFadeSeconds,
                in: 0...RecordingProject.StyleSettingsDefaults.outroFadeMaxSeconds,
                step: 0.05
              )
              Text(outroFadeSeconds, format: .number.precision(.fractionLength(2)))
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
            }
            HStack {
              Text("ソフトズーム係数")
              Slider(
                value: $softZoomScale,
                in: RecordingProject.StyleSettingsDefaults.softZoomScaleMin...RecordingProject.StyleSettingsDefaults.softZoomScaleMax,
                step: 0.01
              )
              Text(softZoomScale, format: .number.precision(.fractionLength(2)))
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
            }
            Text("ソフトズームスタイルおよびイントロ／アウトロフェードで使われます。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.top, 4)
          .onChange(of: introFadeSeconds) { _, _ in persistStyleSettings(project: project) }
          .onChange(of: outroFadeSeconds) { _, _ in persistStyleSettings(project: project) }
          .onChange(of: softZoomScale) { _, _ in persistStyleSettings(project: project) }
        }

        GroupBox("書き出し") {
          VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
            Button("保存先を指定…") {
              ExportSavePanelPresenter.chooseDestination(
                allowedContentTypes: [.mpeg4Movie],
                defaultFilename: defaultExportFilename
              ) { url in
                lastExportOutputURL = url
                beginExport(
                  project: projectStore.current ?? project,
                  to: url
                )
              }
            }
            .disabled(isExporting)
            .accessibilityLabel("書き出し先のファイルを選ぶ")
            .accessibilityHint("MP4 を保存するパスを指定してエンコードを開始します")

            if case .failed = exporter.state, let retryURL = lastExportOutputURL {
              Button(languageStore.localizedFormat("直近のパスでやり直す（%@）", retryURL.lastPathComponent)) {
                beginExport(
                  project: projectStore.current ?? project,
                  to: retryURL
                )
              }
              .disabled(isExporting)
            }

            Button("Copy to Clipboard") {
              let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(defaultExportFilename)
              lastExportOutputURL = temporaryURL
              beginExport(
                project: projectStore.current ?? project,
                to: temporaryURL,
                copyToClipboard: true
              )
            }
            .disabled(isExporting)

            if isExporting {
              ProgressView(value: exporter.progress)
                .frame(maxWidth: 360)
                .accessibilityLabel("書き出しの進行状況")

              Button("書き出しを中止", role: .destructive) {
                exporter.stop()
              }
              .accessibilityLabel("書き出しを中止します")
            }

            switch exporter.state {
            case .idle:
              EmptyView()
            case .exporting:
              Text("書き出し中…")
                .foregroundStyle(.secondary)
            case .finished(let url):
              Text(languageStore.localizedFormat("書き出し完了 %@", url.lastPathComponent))
                .textSelection(.enabled)
                .accessibilityLabel(languageStore.localizedFormat("書き出し完了 %@", url.lastPathComponent))
            case .failed(let message):
              Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .accessibilityLabel("書き出しに失敗しました")
            }
          }
          .padding(.vertical, 6)
        }
      } else {
        VStack(alignment: .leading, spacing: AppUIMetrics.tightSpacing) {
          Image(systemName: "tray")
            .font(.system(size: 36))
            .foregroundStyle(.tertiary)
          Text("プロジェクトが開かれていません")
            .font(.title3.weight(.semibold))
          Text("左の「ワークフロー」から「キャプチャ」で録画するか、既存プロジェクトを開いてください。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ExportEmptyProjectHint")
        }
        .frame(maxWidth: 420, alignment: .leading)
      }

      Spacer()
    }
    .onAppear {
      if let project = projectStore.current {
        selectedPresetID = project.exportPreset
        selectedAspectRatio = project.outputAspectRatio
        selectedStylePreset = project.stylePreset
        introFadeSeconds = project.styleSettings.introFadeSeconds
        outroFadeSeconds = project.styleSettings.outroFadeSeconds
        softZoomScale = project.styleSettings.softZoomScale
        loadExportVisual(from: project.exportVisualSettings)
      }
    }
    .onChange(of: projectStore.current?.id) { _, _ in
      guard let project = projectStore.current else { return }
      selectedPresetID = project.exportPreset
      selectedAspectRatio = project.outputAspectRatio
      selectedStylePreset = project.stylePreset
      introFadeSeconds = project.styleSettings.introFadeSeconds
      outroFadeSeconds = project.styleSettings.outroFadeSeconds
      softZoomScale = project.styleSettings.softZoomScale
      loadExportVisual(from: project.exportVisualSettings)
    }
    .onChange(of: exporter.state) { _, state in
      guard case .failed(let message) = state else { return }
      alertCenter.present(message)
    }
  }

  private var isExporting: Bool {
    if case .exporting = exporter.state { return true }
    return false
  }

  private var exportShadowYSliderRange: ClosedRange<Double> {
    let limit = RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.shadowYOffsetMaxAbsPts
    return -limit ... limit
  }

  private var defaultExportFilename: String {
    "ArcShot 書き出し.mp4"
  }

  private var backgroundColorBinding: Binding<Color> {
    Binding(
      get: { Color(nsColor: ExportViewRGBHex.nsColor(rgbHex: backgroundHex)) },
      set: { backgroundHex = ExportViewRGBHex.rgbHexString(from: NSColor($0)) }
    )
  }

  private var gradientEndColorBinding: Binding<Color> {
    Binding(
      get: { Color(nsColor: ExportViewRGBHex.nsColor(rgbHex: gradientEndHex)) },
      set: { gradientEndHex = ExportViewRGBHex.rgbHexString(from: NSColor($0)) }
    )
  }

  private func loadExportVisual(from settings: RecordingProject.ExportVisualSettings) {
    stageStyle = settings.stageStyle
    backgroundKind = settings.backgroundKind
    backgroundGradientStyle = settings.backgroundGradientStyle
    backgroundHex = settings.backgroundColorHex
    gradientEndHex = settings.gradientEndColorHex
    backgroundBlur = settings.backgroundBlur
    backgroundPadding = settings.backgroundPadding
    contentCornerRadius = settings.contentCornerRadius
    shadowOpacity = settings.dropShadowOpacity
    shadowRadius = settings.shadowRadius
    shadowYOffset = settings.shadowYOffset
    enabledStageOnDisplayCapture = settings.enabledForDisplayCapture
    deviceFramePreset = settings.deviceFramePreset
  }

  private func persistExportVisual(project: RecordingProject) {
    var updated = project
    updated.exportVisualSettings = RecordingProject.ExportVisualSettings(
      stageStyle: stageStyle,
      backgroundKind: backgroundKind,
      backgroundGradientStyle: backgroundGradientStyle,
      backgroundColorHex: backgroundHex,
      gradientEndColorHex: gradientEndHex,
      backgroundBlur: backgroundBlur,
      backgroundPadding: backgroundPadding,
      contentCornerRadius: contentCornerRadius,
      contentInset: 0,
      dropShadowOpacity: shadowOpacity,
      shadowRadius: shadowRadius,
      shadowYOffset: shadowYOffset,
      enabledForDisplayCapture: enabledStageOnDisplayCapture,
      deviceFramePreset: deviceFramePreset
    )
    projectStore.setCurrent(updated)
    projectStore.saveCurrent()
  }

  private func persistStyleSettings(project: RecordingProject) {
    var updated = project
    updated.styleSettings = RecordingProject.StyleSettings(
      introFadeSeconds: introFadeSeconds,
      outroFadeSeconds: outroFadeSeconds,
      softZoomScale: softZoomScale
    )
    projectStore.setCurrent(updated)
    projectStore.saveCurrent()
  }

  private func beginExport(
    project: RecordingProject,
    to url: URL,
    copyToClipboard: Bool = false
  ) {
    Task { @MainActor in
      if project.stylePreset == .cursorFocus,
        !project.cursorSamples.isEmpty,
        let duration = try? await AVURLAsset(url: project.mediaURL).load(.duration),
        duration.isNumeric {
        projectStore.ensureAutoZoomAnalysisForCurrent(assetDurationSeconds: max(0, duration.seconds))
      }

      exporter.export(
        project: projectStore.current ?? project,
        to: url,
        copyToClipboard: copyToClipboard
      )
    }
  }
}

@MainActor
enum ExportSavePanelPresenter {
  static func chooseDestination(
    allowedContentTypes: [UTType],
    defaultFilename: String,
    completion: @escaping @MainActor (URL) -> Void
  ) {
    NSApp.activate(ignoringOtherApps: true)

    let panel = NSSavePanel()
    panel.allowedContentTypes = allowedContentTypes
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = defaultFilename

    let finish: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        completion(url)
      }
    }

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(panel.runModal())
    }
  }
}

private enum ExportViewRGBHex {
  static func nsColor(rgbHex raw: String) -> NSColor {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard body.count == 6, body.allSatisfy(\.isHexDigit), let value = UInt64(body, radix: 16) else {
      let f = RecordingProject.ExportVisualSettings.ExportVisualSettingsDefaults.stageBackgroundFallbackHex
      return nsColor(rgbHex: f)
    }
    let r = CGFloat((value >> 16) & 0xFF) / 255
    let g = CGFloat((value >> 8) & 0xFF) / 255
    let b = CGFloat(value & 0xFF) / 255
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
  }

  static func rgbHexString(from color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    let r = Int(round(rgb.redComponent * 255))
    let g = Int(round(rgb.greenComponent * 255))
    let b = Int(round(rgb.blueComponent * 255))
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}
