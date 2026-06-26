import Foundation

/// Heuristic click-ish events from cursor motion (offline, no input hooks).
enum CursorClickHeuristics {
  enum Defaults {
    /// Second-derivative magnitude on speed (rough Jerk).
    static let minJerk: Double = 12
    static let minSpacingSeconds: Double = 0.12
  }

  /// Proposes click cue times where cursor speed changes abruptly (dwell → quick move or stop).
  static func suggestClickCues(
    samples: [RecordingProject.CursorSample],
    minJerk: Double = Defaults.minJerk,
    minSpacingSeconds: Double = Defaults.minSpacingSeconds,
    existing: [RecordingProject.CursorClickCue] = []
  ) -> [RecordingProject.CursorClickCue] {
    guard samples.count >= 3 else { return [] }
    let sorted = samples.sorted { $0.timeSeconds < $1.timeSeconds }
    var velocities: [(t: Double, v: Double)] = []
    velocities.reserveCapacity(sorted.count - 1)
    for i in 1 ..< sorted.count {
      let dt = sorted[i].timeSeconds - sorted[i - 1].timeSeconds
      guard dt > 1e-6 else { continue }
      let dx = sorted[i].x - sorted[i - 1].x
      let dy = sorted[i].y - sorted[i - 1].y
      let spd = hypot(dx, dy) / dt
      velocities.append((t: sorted[i].timeSeconds, v: spd))
    }
    guard velocities.count >= 3 else { return [] }

    func hasExistingNear(_ time: Double) -> Bool {
      existing.contains { abs($0.timeSeconds - time) < minSpacingSeconds }
    }

    var cues: [RecordingProject.CursorClickCue] = []
    for j in 2 ..< velocities.count {
      let v0 = velocities[j - 2].v
      let v1 = velocities[j - 1].v
      let v2 = velocities[j].v
      let t = velocities[j].t
      let a0 = (v1 - v0) / max(1e-6, velocities[j - 1].t - velocities[j - 2].t)
      let a1 = (v2 - v1) / max(1e-6, velocities[j].t - velocities[j - 1].t)
      let jerk = abs(a1 - a0) / max(1e-6, velocities[j].t - velocities[j - 2].t + 1e-9)
      guard jerk >= minJerk else { continue }
      guard !hasExistingNear(t) else { continue }
      guard !cues.contains(where: { abs($0.timeSeconds - t) < minSpacingSeconds }) else { continue }
      cues.append(RecordingProject.CursorClickCue(timeSeconds: t))
    }
    return cues.sorted { $0.timeSeconds < $1.timeSeconds }
  }
}
