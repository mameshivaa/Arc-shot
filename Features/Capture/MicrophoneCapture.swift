import AVFoundation
import CoreMedia
import Foundation

// MARK: - MicrophoneCapture
//
// INVARIANT (docs/INVARIANTS.md §2 — do not break):
//   1. Never call session.startRunning() between beginConfiguration() and commitConfiguration().
//      Doing so throws at runtime and froze the launcher at countdown "1" when mic was enabled.
//   2. Configure + startRunning on `queue`, not MainActor. RecordingCoordinator awaits start().
//   3. On error paths before commit, call commitConfiguration() then throw.
//
// Samples are forwarded to RecordingWriterSession via onSampleBuffer on the same serial queue.

final class MicrophoneCapture: NSObject, @unchecked Sendable {
  enum MicrophoneError: LocalizedError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
      switch self {
      case .noDevice: "マイク機器が見つかりません。"
      case .cannotAddInput: "マイク入力を追加できませんでした。"
      case .cannotAddOutput: "マイク出力を追加できませんでした。"
      }
    }
  }

  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private let queue = DispatchQueue(label: AppIdentifiers.DispatchQueueLabels.microphone)

  var onSampleBuffer: ((CMSampleBuffer) -> Void)?

  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          try self.configureAndStartOnQueue()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func configureAndStartOnQueue() throws {
    // INVARIANT §2: entire configuration block must finish with commitConfiguration()
    // BEFORE startRunning(). defer { commit } + startRunning() inside the same scope is WRONG.
    session.beginConfiguration()
    session.sessionPreset = .high

    guard let device = AVCaptureDevice.default(for: .audio) else {
      session.commitConfiguration()
      throw MicrophoneError.noDevice
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw MicrophoneError.cannotAddInput
    }
    session.addInput(input)

    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw MicrophoneError.cannotAddOutput
    }
    session.addOutput(output)

    output.setSampleBufferDelegate(self, queue: queue)
    session.commitConfiguration()
    session.startRunning()
  }

  func stop() {
    queue.async {
      self.session.stopRunning()
    }
  }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    onSampleBuffer?(sampleBuffer)
  }
}

