@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class ExportReaderWriterSession: @unchecked Sendable {
  struct Input {
    var readerAsset: AVAsset
    var readerTimeRange: CMTimeRange?
    var temporaryOutputURL: URL
    var videoOutput: AVAssetReaderOutput
    var videoInput: AVAssetWriterInput
    var audioOutput: AVAssetReaderOutput?
    var audioInput: AVAssetWriterInput?
    var readerProgressBase: CMTime
    var durationSeconds: Double
    var exportQueue: DispatchQueue
  }

  enum Result {
    case success
    case readerFailure(String)
    case writerFailure(String)
    case setupFailure(String)
  }

  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?

  func start(
    input: Input,
    progress: @escaping @Sendable (Double) -> Void,
    onFinish: @escaping @Sendable (Result) -> Void
  ) {
    do {
      let reader = try AVAssetReader(asset: input.readerAsset)
      if let readerTimeRange = input.readerTimeRange {
        reader.timeRange = readerTimeRange
      }

      let writer = try AVAssetWriter(outputURL: input.temporaryOutputURL, fileType: .mp4)
      writer.shouldOptimizeForNetworkUse = true

      guard reader.canAdd(input.videoOutput) else {
        throw ExportError("読み込み側にビデオ出力を追加できませんでした。")
      }
      guard writer.canAdd(input.videoInput) else {
        throw ExportError("書き込み側にビデオ入力を追加できませんでした。")
      }
      reader.add(input.videoOutput)
      writer.add(input.videoInput)

      if let audioOutput = input.audioOutput, let audioInput = input.audioInput {
        if reader.canAdd(audioOutput) { reader.add(audioOutput) }
        if writer.canAdd(audioInput) { writer.add(audioInput) }
      }

      self.reader = reader
      self.writer = writer

      guard reader.startReading() else {
        throw ExportError(reader.error?.localizedDescription ?? "読み込みを開始できませんでした。")
      }
      guard writer.startWriting() else {
        throw ExportError(writer.error?.localizedDescription ?? "書き込みを開始できませんでした。")
      }

      writer.startSession(atSourceTime: input.readerProgressBase)
      pump(
        reader: reader,
        writer: writer,
        input: input,
        progress: progress,
        onFinish: onFinish
      )
    } catch {
      onFinish(.setupFailure(String(describing: error)))
    }
  }

  func cancel() {
    reader?.cancelReading()
    writer?.cancelWriting()
    reader = nil
    writer = nil
  }

  private func pump(
    reader: AVAssetReader,
    writer: AVAssetWriter,
    input: Input,
    progress: @escaping @Sendable (Double) -> Void,
    onFinish: @escaping @Sendable (Result) -> Void
  ) {
    let group = DispatchGroup()

    nonisolated(unsafe) let sendableReader = reader
    nonisolated(unsafe) let sendableWriter = writer
    nonisolated(unsafe) let sendableVideoOutput = input.videoOutput
    nonisolated(unsafe) let sendableVideoInput = input.videoInput
    nonisolated(unsafe) let sendableAudioOutput = input.audioOutput
    nonisolated(unsafe) let sendableAudioInput = input.audioInput

    group.enter()
    sendableVideoInput.requestMediaDataWhenReady(on: input.exportQueue) {
      while sendableVideoInput.isReadyForMoreMediaData {
        if sendableReader.status != .reading {
          sendableVideoInput.markAsFinished()
          group.leave()
          return
        }
        let finished: Bool = autoreleasepool {
          guard let sample = sendableVideoOutput.copyNextSampleBuffer() else {
            return true
          }
          progress(Self.progressRatio(sample: sample, baseStart: input.readerProgressBase, durationSeconds: input.durationSeconds))
          _ = sendableVideoInput.append(sample)
          return false
        }
        if finished {
          sendableVideoInput.markAsFinished()
          group.leave()
          return
        }
      }
    }

    if let unwrappedAudioOutput = sendableAudioOutput, let unwrappedAudioInput = sendableAudioInput {
      nonisolated(unsafe) let safeAudioOutput = unwrappedAudioOutput
      nonisolated(unsafe) let safeAudioInput = unwrappedAudioInput
      group.enter()
      safeAudioInput.requestMediaDataWhenReady(on: input.exportQueue) {
        while safeAudioInput.isReadyForMoreMediaData {
          if sendableReader.status != .reading {
            safeAudioInput.markAsFinished()
            group.leave()
            return
          }
          let finished: Bool = autoreleasepool {
            guard let sample = safeAudioOutput.copyNextSampleBuffer() else {
              return true
            }
            _ = safeAudioInput.append(sample)
            return false
          }
          if finished {
            safeAudioInput.markAsFinished()
            group.leave()
            return
          }
        }
      }
    }

    group.notify(queue: input.exportQueue) {
      sendableWriter.finishWriting {
        if sendableReader.status == .failed {
          onFinish(.readerFailure(sendableReader.error?.localizedDescription ?? "書き出しに失敗しました（読み込み）。"))
          return
        }
        if sendableWriter.status == .failed {
          onFinish(.writerFailure(sendableWriter.error?.localizedDescription ?? "書き出しに失敗しました（書き込み）。"))
          return
        }
        onFinish(.success)
      }
    }
  }

  private static func progressRatio(sample: CMSampleBuffer, baseStart: CMTime, durationSeconds: Double) -> Double {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let elapsed = CMTimeSubtract(pts, baseStart)
    guard elapsed.isNumeric else { return 0 }
    return max(0, min(1, elapsed.seconds / durationSeconds))
  }
}
