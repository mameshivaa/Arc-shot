import Foundation
import simd

struct CameraFrame: Equatable {
  var timeSeconds: Double
  var position: simd_double2
  var scale: Double
}

struct SpringDamperCamera {
  struct Config {
    var positionStiffness: Double = 70
    var positionDamping: Double = 20
    var scaleStiffness: Double = 55
    var scaleDamping: Double = 16
    var maxPositionVelocity: Double = 1.45
    var maxScaleVelocity: Double = 3.2
    var maxScale: Double = 1.9
    var simulationHz: Double = 120
    var urgencyStiffnessMultiplier: Double = 1.45
    var urgencyDampingMultiplier: Double = 1.18
    var minIntentTargetBlend: Double = 0.97
    var noIntentUrgency: Double = 0.02
    var positionDeadband: Double = 0.012
    var scaleDeadband: Double = 0.015
    var noIntentReturnDelaySeconds: Double = 0.9
    var overviewPosition: simd_double2 = simd_double2(0.5, 0.5)
  }

  private(set) var position: simd_double2
  private(set) var scale: Double
  private var positionVelocity: simd_double2
  private var scaleVelocity: Double
  private let config: Config

  init(initialPosition: simd_double2 = simd_double2(0.5, 0.5), initialScale: Double = 1.0, config: Config = Config()) {
    self.position = initialPosition
    self.scale = initialScale
    self.positionVelocity = .zero
    self.scaleVelocity = 0
    self.config = config
  }

  mutating func step(
    targetPosition: simd_double2,
    targetScale: Double,
    urgency: Double,
    dt: Double
  ) {
    guard dt > 1e-9 else { return }
    let u = max(0, min(1, urgency))
    let stiffMul = 1.0 + u * (config.urgencyStiffnessMultiplier - 1.0)
    let dampMul = 1.0 + u * (config.urgencyDampingMultiplier - 1.0)

    let posStiff = config.positionStiffness * stiffMul
    let posDamp = config.positionDamping * dampMul

    let posError = targetPosition - position
    let posAccel = posStiff * posError - posDamp * positionVelocity
    positionVelocity = positionVelocity + posAccel * dt
    let posSpeed = simd_length(positionVelocity)
    if posSpeed > config.maxPositionVelocity {
      positionVelocity = positionVelocity * (config.maxPositionVelocity / posSpeed)
    }
    position = position + positionVelocity * dt
    position = simd_clamp(position, simd_double2(0, 0), simd_double2(1, 1))

    let scaleStiff = config.scaleStiffness * stiffMul
    let scaleDamp = config.scaleDamping * dampMul
    let scaleError = targetScale - scale
    let scaleAccel = scaleStiff * scaleError - scaleDamp * scaleVelocity
    scaleVelocity += scaleAccel * dt
    scaleVelocity = max(-config.maxScaleVelocity, min(config.maxScaleVelocity, scaleVelocity))
    scale += scaleVelocity * dt
    scale = max(1.0, min(config.maxScale, scale))
  }

  static func simulate(
    intents: [ZoomIntent],
    cursorSamples: [RecordingProject.CursorSample],
    durationSeconds: Double,
    config: Config = Config()
  ) -> [CameraFrame] {
    let samples = cursorSamples.sorted { $0.timeSeconds < $1.timeSeconds }
    guard durationSeconds > 0 else { return [] }

    let dt = 1.0 / config.simulationHz
    let frameCount = Int(ceil(durationSeconds * config.simulationHz))
    guard frameCount > 0 else { return [] }

    let initialPos = ActivityClassifier.interpolatedPosition(at: 0, samples: samples)
    var camera = SpringDamperCamera(initialPosition: initialPos, initialScale: 1.0, config: config)

    var frames: [CameraFrame] = []
    frames.reserveCapacity(frameCount)

    let sortedIntents = intents.sorted { $0.startSeconds < $1.startSeconds }
    var lastIntentTarget: (endSeconds: Double, position: simd_double2, scale: Double)?

    for i in 0..<frameCount {
      let t = Double(i) * dt
      let cursorPos = ActivityClassifier.interpolatedPosition(at: t, samples: samples)
      let activeIntent = sortedIntents.last { $0.startSeconds <= t && $0.endSeconds > t }

      let targetScale: Double
      let targetPosition: simd_double2
      let urgency: Double

      if let intent = activeIntent {
        targetScale = intent.targetScale
        let blend = intentBlend(t: t, intent: intent)
        let targetBlend = max(config.minIntentTargetBlend, blend)
        targetPosition = simd_mix(cursorPos, intent.targetAnchor, simd_double2(repeating: targetBlend))
        urgency = intent.urgency
        lastIntentTarget = (intent.endSeconds, targetPosition, targetScale)
      } else if let last = lastIntentTarget,
                t - last.endSeconds <= config.noIntentReturnDelaySeconds {
        targetScale = last.scale
        targetPosition = last.position
        urgency = config.noIntentUrgency
      } else {
        targetScale = 1.0
        targetPosition = config.overviewPosition
        urgency = config.noIntentUrgency
      }

      let stabilizedPosition = simd_distance(targetPosition, camera.position) < config.positionDeadband
        ? camera.position
        : targetPosition
      let stabilizedScale = abs(targetScale - camera.scale) < config.scaleDeadband
        ? camera.scale
        : targetScale

      camera.step(targetPosition: stabilizedPosition, targetScale: stabilizedScale, urgency: urgency, dt: dt)

      frames.append(CameraFrame(
        timeSeconds: t,
        position: camera.position,
        scale: camera.scale))
    }

    return frames
  }

  private static func intentBlend(t: Double, intent: ZoomIntent) -> Double {
    let duration = intent.durationSeconds
    guard duration > 0.01 else { return 1.0 }
    let local = (t - intent.startSeconds) / duration
    let rampIn = smoothstep(edge0: 0, edge1: 0.15, x: local)
    let rampOut = 1.0 - smoothstep(edge0: 0.85, edge1: 1.0, x: local)
    return rampIn * rampOut
  }
}

private func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
  let t = max(0, min(1, (x - edge0) / max(1e-9, edge1 - edge0)))
  return t * t * (3 - 2 * t)
}
