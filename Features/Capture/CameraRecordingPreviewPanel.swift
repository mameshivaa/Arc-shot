import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class CameraRecordingPreviewPanel {
  private var panel: NSPanel?
  private var previewView: CameraPreviewHostView?
  private var loadingHostingController: NSHostingController<AnyView>?

  func update(session: AVCaptureSession?, isVisible: Bool, isLoading: Bool = false) {
    guard isVisible else {
      dismiss()
      return
    }
    ensurePanel()
    if let session {
      previewView?.attach(session: session)
      loadingHostingController?.view.isHidden = true
    } else if isLoading {
      previewView?.detach()
      showLoadingOverlay()
    } else {
      previewView?.detach()
      loadingHostingController?.view.isHidden = true
    }
    layoutOnActiveScreen()
    panel?.orderFrontRegardless()
  }

  func dismiss() {
    previewView?.detach()
    loadingHostingController?.view.isHidden = true
    panel?.orderOut(nil)
  }

  private func showLoadingOverlay() {
    guard let previewView else { return }
    let root = AnyView(
      ZStack {
        RoundedRectangle(cornerRadius: CameraPiPDefaults.cornerRadiusPts * 0.55, style: .continuous)
          .fill(Color.black.opacity(0.55))
        ProgressView()
          .controlSize(.regular)
      }
    )
    if let loadingHostingController {
      loadingHostingController.rootView = root
      loadingHostingController.view.isHidden = false
    } else {
      let host = NSHostingController(rootView: root)
      host.view.frame = previewView.bounds
      host.view.autoresizingMask = [.width, .height]
      configureTransparentHostingView(host.view)
      previewView.addSubview(host.view)
      loadingHostingController = host
    }
  }

  private func configureTransparentHostingView(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
  }

  private func ensurePanel() {
    guard panel == nil else { return }
    let contentRect = NSRect(
      x: 0,
      y: 0,
      width: CameraPiPDefaults.previewPanelWidth,
      height: CameraPiPDefaults.previewPanelHeight
    )
    let panel = NSPanel(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isMovable = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false

    let previewView = CameraPreviewHostView(frame: contentRect)
    previewView.wantsLayer = true
    panel.contentView = previewView
    self.previewView = previewView
    self.panel = panel
  }

  private func layoutOnActiveScreen() {
    guard let panel else { return }
    let screen = NSScreen.main ?? NSScreen.screens.first!
    let visible = screen.visibleFrame
    let width = CameraPiPDefaults.previewPanelWidth
    let height = CameraPiPDefaults.previewPanelHeight
    let margin = CameraPiPDefaults.previewScreenMargin
    let origin = CGPoint(
      x: visible.maxX - width - margin,
      y: visible.minY + margin
    )
    panel.setFrame(CGRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
  }
}

private final class CameraPreviewHostView: NSView {
  private var previewLayer: AVCaptureVideoPreviewLayer?

  override func layout() {
    super.layout()
    previewLayer?.frame = bounds
  }

  func attach(session: AVCaptureSession) {
    if previewLayer == nil {
      let layer = AVCaptureVideoPreviewLayer(session: session)
      layer.videoGravity = .resizeAspectFill
      layer.cornerRadius = CameraPiPDefaults.cornerRadiusPts * 0.55
      layer.masksToBounds = true
      self.layer?.addSublayer(layer)
      previewLayer = layer
    } else if previewLayer?.session !== session {
      previewLayer?.session = session
    }
    previewLayer?.frame = bounds
  }

  func detach() {
    previewLayer?.session = nil
  }
}
