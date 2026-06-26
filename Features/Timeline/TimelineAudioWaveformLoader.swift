import AVFoundation

/// Lightweight peak envelope bins for scrub UI (first audio track). Returns empty array when there is no audio.
enum TimelineAudioWaveformLoader {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static let waveformBinCap = 1_024

  /// How peak samples are mapped into timeline bins for the editor waveform UI.
  enum PeakBinDistribution {
    /// Spread peaks evenly by sample order (best when capture PTS does not match video duration).
    case evenSampleSpread
    /// Map by presentation timestamp within the asset duration.
    case presentationTime
  }

  static func peakEnvelopeNormalizedBins(
    assetURL: URL,
    assetDurationSeconds: Double,
    maxBins: Int = 400,
    sourceRange: ClosedRange<Double>? = nil,
    trackIndex: Int = 0,
    distribution: PeakBinDistribution = .evenSampleSpread
  ) async throws -> [Float] {
    let avAsset = AVURLAsset(url: assetURL)
    let audioTracks = try await avAsset.loadTracks(withMediaType: .audio)
    guard trackIndex >= 0, trackIndex < audioTracks.count else {
      return []
    }
    let audioTrack = audioTracks[trackIndex]

    let reader = try AVAssetReader(asset: avAsset)

    if let sourceRange {
      let start = CMTime(seconds: max(0, sourceRange.lowerBound), preferredTimescale: 600)
      let end = CMTime(seconds: sourceRange.upperBound, preferredTimescale: 600)
      reader.timeRange = CMTimeRange(start: start, end: end)
    }

    let output = AVAssetReaderTrackOutput(
      track: audioTrack,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw Failure(message: "波形用リーダーに音声トラック出力を追加できませんでした。") }
    reader.add(output)
    guard reader.startReading() else {
      throw Failure(message: reader.error?.localizedDescription ?? "波形の読み込みを開始できませんでした。")
    }

    let rangeStart: Double
    let rangeDuration: Double
    if let sourceRange {
      rangeStart = max(0, sourceRange.lowerBound)
      rangeDuration = max(0.001, sourceRange.upperBound - rangeStart)
    } else {
      rangeStart = 0
      rangeDuration = max(0.001, assetDurationSeconds)
    }

    let bins = min(maxBins, waveformBinCap)
    var samplePeaks: [Float] = []
    var sums = [Double](repeating: 0, count: bins)
    var counts = [Int](repeating: 0, count: bins)

    while reader.status == AVAssetReader.Status.reading {
      guard let sb = output.copyNextSampleBuffer() else { break }
      if distribution == .presentationTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        guard pts >= rangeStart, pts <= rangeStart + rangeDuration else { continue }
      }

      guard let blockBuf = CMSampleBufferGetDataBuffer(sb) else { continue }
      var lengthAtOffset = 0
      var totalLength = 0
      var dataPointer: UnsafeMutablePointer<Int8>?
      CMBlockBufferGetDataPointer(blockBuf, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
      guard let ptr = dataPointer, totalLength > 0 else { continue }

      let sampleCount = totalLength / MemoryLayout<Int16>.size
      guard sampleCount > 0 else { continue }
      var peakAbs: Float = 0
      ptr.withMemoryRebound(to: Int16.self, capacity: sampleCount) { sPtr in
        let ints = UnsafeBufferPointer(start: sPtr, count: sampleCount)
        for s in ints {
          peakAbs = max(peakAbs, Float(abs(Float(s) / Float(Int16.max))))
        }
      }

      switch distribution {
      case .evenSampleSpread:
        samplePeaks.append(peakAbs)
      case .presentationTime:
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let u = (pts - rangeStart) / rangeDuration
        let ixRaw = Int(floor(Double(bins - 1) * u))
        let ix = Swift.min(Swift.max(0, ixRaw), bins - 1)
        sums[ix] += Double(peakAbs)
        counts[ix] += 1
      }
    }

    guard reader.status != AVAssetReader.Status.failed else {
      throw Failure(message: reader.error?.localizedDescription ?? "波形の読み込みに失敗しました。")
    }

    var peaks: [Float]
    switch distribution {
    case .evenSampleSpread:
      peaks = normalizedBinsFromEvenSampleSpread(samplePeaks, bins: bins)
    case .presentationTime:
      peaks = (0 ..< bins).map { idx -> Float in
        guard counts[idx] > 0 else { return 0 }
        let v = sums[idx] / Double(counts[idx])
        return max(0, min(1, Float(v)))
      }
      let m = peaks.max() ?? 0
      if m > 1e-6 {
        peaks = peaks.map { $0 / m }
      }
    }
    return peaks
  }

  private static func normalizedBinsFromEvenSampleSpread(_ samplePeaks: [Float], bins: Int) -> [Float] {
    guard !samplePeaks.isEmpty else { return [] }
    var sums = [Double](repeating: 0, count: bins)
    var counts = [Int](repeating: 0, count: bins)
    let sampleCount = samplePeaks.count
    for (index, peak) in samplePeaks.enumerated() {
      let u = sampleCount <= 1 ? 0.5 : Double(index) / Double(sampleCount - 1)
      let ixRaw = Int(floor(Double(bins - 1) * u))
      let ix = Swift.min(Swift.max(0, ixRaw), bins - 1)
      sums[ix] += Double(peak)
      counts[ix] += 1
    }
    var peaks = (0 ..< bins).map { idx -> Float in
      guard counts[idx] > 0 else { return 0 }
      let v = sums[idx] / Double(counts[idx])
      return max(0, min(1, Float(v)))
    }
    let m = peaks.max() ?? 0
    if m > 1e-6 {
      peaks = peaks.map { $0 / m }
    }
    return peaks
  }

  struct ClipWaveformInput {
    var sourceURL: URL
    var sourceStartSeconds: Double
    var durationSeconds: Double
    var rate: Double
    var timelineStartSeconds: Double
  }

  static func peakEnvelopeForTimeline(
    clips: [ClipWaveformInput],
    totalDuration: Double,
    maxBins: Int = 400
  ) async throws -> [Float] {
    let bins = min(maxBins, waveformBinCap)
    guard totalDuration > 0.001, !clips.isEmpty else { return [] }

    var segments: [(timelineStart: Double, duration: Double, peaks: [Float])] = []
    for clip in clips {
      let sourceDuration = clip.durationSeconds * clip.rate
      guard sourceDuration > 0.001 else { continue }
      let clipBins = max(1, Int(round(Double(bins) * clip.durationSeconds / totalDuration)))
      let range = clip.sourceStartSeconds ... (clip.sourceStartSeconds + sourceDuration)
      let peaks = try await peakEnvelopeNormalizedBins(
        assetURL: clip.sourceURL,
        assetDurationSeconds: sourceDuration,
        maxBins: clipBins,
        sourceRange: range
      )
      segments.append((clip.timelineStartSeconds, clip.durationSeconds, peaks))
    }

    return assembleBins(segments: segments, totalDuration: totalDuration, bins: bins)
  }

  static func assembleBins(
    segments: [(timelineStart: Double, duration: Double, peaks: [Float])],
    totalDuration: Double,
    bins: Int
  ) -> [Float] {
    guard totalDuration > 0, bins > 0, !segments.isEmpty else { return [] }
    var result = [Float](repeating: 0, count: bins)

    for seg in segments {
      guard !seg.peaks.isEmpty, seg.duration > 0 else { continue }
      let startBin = Int(floor(seg.timelineStart / totalDuration * Double(bins)))
      let endBin = Int(floor((seg.timelineStart + seg.duration) / totalDuration * Double(bins)))
      let spanBins = max(1, endBin - startBin)

      for i in 0 ..< spanBins {
        let destIdx = startBin + i
        guard destIdx >= 0, destIdx < bins else { continue }
        let srcIdx = min(seg.peaks.count - 1, i * seg.peaks.count / spanBins)
        result[destIdx] = max(result[destIdx], seg.peaks[srcIdx])
      }
    }

    let m = result.max() ?? 0
    if m > 1e-6 {
      result = result.map { $0 / m }
    }
    return result
  }

  static func peakEnvelopeMixed(
    assetURL: URL,
    assetDurationSeconds: Double,
    maxBins: Int = 400,
    sourceRange: ClosedRange<Double>? = nil
  ) async throws -> [Float] {
    let audioTrackCount = try await AVURLAsset(url: assetURL).loadTracks(withMediaType: .audio).count
    guard audioTrackCount > 0 else { return [] }

    var mixed = [Float]()
    for trackIndex in 0..<audioTrackCount {
      let bins = try await peakEnvelopeNormalizedBins(
        assetURL: assetURL,
        assetDurationSeconds: assetDurationSeconds,
        maxBins: maxBins,
        sourceRange: sourceRange,
        trackIndex: trackIndex,
        distribution: .presentationTime
      )
      guard !bins.isEmpty else { continue }
      if mixed.isEmpty {
        mixed = bins
        continue
      }
      let count = max(mixed.count, bins.count)
      if mixed.count < count {
        mixed.append(contentsOf: Array(repeating: Float(0), count: count - mixed.count))
      }
      for index in 0..<bins.count {
        mixed[index] = max(mixed[index], bins[index])
      }
    }
    let peak = mixed.max() ?? 0
    if peak > 1e-6 {
      mixed = mixed.map { $0 / peak }
    }
    return mixed
  }

  static func peakEnvelopeByRole(
    assetURL: URL,
    roles: [RecordingProject.AudioTrackSettings.Role]?,
    bgmURL: URL?,
    assetDurationSeconds: Double,
    maxBins: Int = 400
  ) async throws -> [(role: RecordingProject.AudioTrackSettings.Role, bins: [Float])] {
    typealias Role = RecordingProject.AudioTrackSettings.Role
    var result: [(role: Role, bins: [Float])] = []

    guard let roles, !roles.isEmpty else {
      // フォールバック: 従来互換としてトラック0をマイク波形として扱う。
      let bins = try await peakEnvelopeNormalizedBins(
        assetURL: assetURL,
        assetDurationSeconds: assetDurationSeconds,
        maxBins: maxBins,
        trackIndex: 0
      )
      if !bins.isEmpty {
        result.append((.microphone, bins))
      }
      return result
    }

    // recordedTrackRoles の各エントリは録音ファイル内の音声トラック順に対応する（BGM は別ファイル）。
    var recordedTrackIndex = 0
    let audioTrackCount = try await AVURLAsset(url: assetURL).loadTracks(withMediaType: .audio).count
    for role in roles {
      guard role != .backgroundMusic else { continue }
      guard recordedTrackIndex < audioTrackCount else { break }
      let bins = try await peakEnvelopeNormalizedBins(
        assetURL: assetURL,
        assetDurationSeconds: assetDurationSeconds,
        maxBins: maxBins,
        trackIndex: recordedTrackIndex
      )
      recordedTrackIndex += 1
      guard !bins.isEmpty else { continue }
      result.append((role, bins))
    }

    if result.isEmpty, audioTrackCount > 0 {
      let bins = try await peakEnvelopeNormalizedBins(
        assetURL: assetURL,
        assetDurationSeconds: assetDurationSeconds,
        maxBins: maxBins,
        trackIndex: 0
      )
      if !bins.isEmpty {
        result.append((.microphone, bins))
      }
    }

    // BGM は録音ファイルではなく別アセットの先頭音声トラックを読む。
    if roles.contains(.backgroundMusic), let bgmURL {
      let bins = try await peakEnvelopeNormalizedBins(
        assetURL: bgmURL,
        assetDurationSeconds: assetDurationSeconds,
        maxBins: maxBins,
        trackIndex: 0
      )
      if !bins.isEmpty {
        result.append((.backgroundMusic, bins))
      }
    }

    return result
  }
}
