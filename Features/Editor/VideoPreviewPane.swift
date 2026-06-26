@preconcurrency import AVFoundation
import AVKit
import SwiftUI

struct VideoPreviewPane: View {
  var project: RecordingProject
  @Environment(AppLanguageStore.self) private var languageStore

  @State private var thumbnail: NSImage?
  @State private var metadataText = "Loading recording..."
  @State private var loadTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: AppUIMetrics.groupSpacing) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.secondary.opacity(0.10))

        InlineAVPlayerView(url: project.mediaURL)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .padding(10)

        if thumbnail == nil {
          VStack(spacing: 8) {
            Image(systemName: "film")
              .font(.system(size: 32, weight: .medium))
              .foregroundStyle(.secondary)
            Text("Loading preview")
              .font(.headline)
            Text(metadataText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .padding()
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
      )
      .aspectRatio(project.outputAspectRatio.previewAspectRatio, contentMode: .fit)

      HStack(spacing: AppUIMetrics.groupSpacing) {
        Button("アプリ内で再生") {
          InAppVideoPreviewWindowController.shared.show(
            url: project.mediaURL,
            title: languageStore.localizedProjectDisplayTitle(
              storedTitle: project.title,
              createdAt: project.createdAt
            )
          )
        }
        .buttonStyle(.borderedProminent)

        Text(metadataText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer()
      }
    }
    .onAppear {
      loadPreview()
    }
    .onChange(of: project.id) { _, _ in
      loadPreview()
    }
    .onDisappear {
      loadTask?.cancel()
      loadTask = nil
    }
  }

  private func loadPreview() {
    loadTask?.cancel()
    thumbnail = nil
    metadataText = "Loading recording..."

    let url = project.mediaURL
    loadTask = Task {
      let loaded = await Self.loadPreviewInfo(url: url)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        thumbnail = loaded.thumbnail
        metadataText = loaded.metadataText
      }
    }
  }

  private static func loadPreviewInfo(url: URL) async -> (thumbnail: NSImage?, metadataText: String) {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    do {
      let duration = try await asset.load(.duration)
      let tracks = try await asset.loadTracks(withMediaType: .video)
      let size = try await tracks.first?.load(.naturalSize) ?? .zero
      let seconds = max(0, CMTimeGetSeconds(duration))
      let thumb = try? await makeThumbnail(asset: asset)
      let text = "\(formatDuration(seconds)) · \(Int(size.width)) x \(Int(size.height))"
      return (thumb, text)
    } catch {
      return (nil, "Could not load recording metadata")
    }
  }

  private static func makeThumbnail(asset: AVAsset) async throws -> NSImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 720)
    let image = try await generator.image(at: .zero).image
    return NSImage(cgImage: image, size: .zero)
  }

  private static func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

private extension AspectRatioPreset {
  var previewAspectRatio: CGFloat {
    switch self {
    case .sixteenNine:
      return 16.0 / 9.0
    case .nineSixteen:
      return 9.0 / 16.0
    case .oneOne:
      return 1.0
    case .fourThree:
      return 4.0 / 3.0
    case .threeFour:
      return 3.0 / 4.0
    }
  }
}

@MainActor
final class InAppVideoPreviewWindowController: NSObject, NSWindowDelegate {
  static let shared = InAppVideoPreviewWindowController()

  private var window: NSWindow?
  private var player: AVPlayer?

  func show(url: URL, title: String) {
    player?.pause()

    let player = AVPlayer(url: url)
    let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 1040, height: 680))
    playerView.player = player
    playerView.controlsStyle = .floating
    playerView.videoGravity = .resizeAspect

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.minSize = NSSize(width: 640, height: 400)
    window.contentView = playerView
    window.delegate = self
    window.center()

    self.player = player
    self.window = window

    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    player.play()
  }

  func windowWillClose(_ notification: Notification) {
    guard notification.object as? NSWindow === window else { return }
    player?.pause()
    player = nil
    window = nil
  }
}

private struct InlineAVPlayerView: NSViewRepresentable {
  var url: URL

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> AVPlayerView {
    let playerView = AVPlayerView()
    playerView.controlsStyle = .floating
    playerView.videoGravity = .resizeAspect
    updatePlayerView(playerView, coordinator: context.coordinator)
    return playerView
  }

  func updateNSView(_ playerView: AVPlayerView, context: Context) {
    updatePlayerView(playerView, coordinator: context.coordinator)
  }

  static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
    coordinator.player?.pause()
    coordinator.player = nil
    coordinator.url = nil
    playerView.player = nil
  }

  private func updatePlayerView(_ playerView: AVPlayerView, coordinator: Coordinator) {
    guard coordinator.url != url else { return }
    coordinator.player?.pause()

    let player = AVPlayer(url: url)
    coordinator.url = url
    coordinator.player = player
    playerView.player = player
  }

  final class Coordinator {
    var url: URL?
    var player: AVPlayer?
  }
}
