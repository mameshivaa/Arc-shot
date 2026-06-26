import XCTest
import CoreGraphics
import simd

@testable import ArcShot

final class AutoZoomPipelineTests: XCTestCase {

  // MARK: - ActivityClassifier

  func testIdleCursorClassifiesAsIdle() {
    let samples = (0..<120).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.5, y: 0.5)
    }
    let spans = ActivityClassifier.classify(
      cursorSamples: samples, inputEvents: [], durationSeconds: 2.0)
    XCTAssertFalse(spans.isEmpty)
    XCTAssertTrue(spans.contains { $0.activity == .idle })
  }

  func testClickEventClassifiesAsClicking() {
    let samples = (0..<180).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0, x: 0.3, y: 0.4)
    }
    let events = [
      RecordingProject.InputEvent(
        timeSeconds: 1.0, kind: .mouseDown,
        x: 0.3, y: 0.4, modifierFlagsRaw: 0),
      RecordingProject.InputEvent(
        timeSeconds: 1.05, kind: .mouseUp,
        x: 0.3, y: 0.4, modifierFlagsRaw: 0),
    ]
    let spans = ActivityClassifier.classify(
      cursorSamples: samples, inputEvents: events, durationSeconds: 3.0)
    let clickSpans = spans.filter {
      if case .clicking = $0.activity { return true }
      return false
    }
    XCTAssertFalse(clickSpans.isEmpty)
  }

  func testTypingBurstClassifiesAsTyping() {
    let samples = (0..<300).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0, x: 0.5, y: 0.5)
    }
    var events: [RecordingProject.InputEvent] = []
    for i in 0..<10 {
      events.append(RecordingProject.InputEvent(
        timeSeconds: 1.0 + Double(i) * 0.15,
        kind: .keyDown, keyCode: UInt16(i), modifierFlagsRaw: 0))
    }
    let spans = ActivityClassifier.classify(
      cursorSamples: samples, inputEvents: events, durationSeconds: 5.0)
    let typingSpans = spans.filter {
      if case .typing = $0.activity { return true }
      return false
    }
    XCTAssertFalse(typingSpans.isEmpty)
  }

  func testFastMovementClassifiesAsNavigating() {
    var samples: [RecordingProject.CursorSample] = []
    for i in 0..<120 {
      let t = Double(i) / 60.0
      let x = t < 1.0 ? 0.1 : 0.1 + (t - 1.0) * 1.5
      samples.append(RecordingProject.CursorSample(
        timeSeconds: t, x: min(1, x), y: 0.5))
    }
    let spans = ActivityClassifier.classify(
      cursorSamples: samples, inputEvents: [], durationSeconds: 2.0)
    let navSpans = spans.filter { $0.activity == .navigating }
    XCTAssertFalse(navSpans.isEmpty)
  }

  // MARK: - ZoomIntentPlanner

  func testClickActivityProducesZoomIntent() {
    let activities = [
      ActivitySpan(
        activity: .clicking(anchor: simd_double2(0.3, 0.4)),
        startSeconds: 1.0, endSeconds: 1.5,
        anchor: simd_double2(0.3, 0.4)),
    ]
    let intents = ZoomIntentPlanner.plan(
      activities: activities, durationSeconds: 3.0)
    XCTAssertEqual(intents.count, 1)
    XCTAssertEqual(intents[0].targetKind, .clickTarget)
    XCTAssertGreaterThan(intents[0].targetScale, 1.0)
    XCTAssertLessThanOrEqual(intents[0].targetScale, 1.35)
    XCTAssertGreaterThan(intents[0].urgency, 0.5)
  }

  func testIdleActivityProducesNoZoomIntent() {
    let activities = [
      ActivitySpan(
        activity: .idle,
        startSeconds: 0.0, endSeconds: 2.0,
        anchor: simd_double2(0.2, 0.8)),
    ]

    let intents = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 2.0)

    XCTAssertTrue(intents.isEmpty)
  }

  func testNavigationProducesNoZoom() {
    let activities = [
      ActivitySpan(
        activity: .navigating,
        startSeconds: 0.0, endSeconds: 1.0,
        anchor: simd_double2(0.5, 0.5)),
    ]
    let intents = ZoomIntentPlanner.plan(
      activities: activities, durationSeconds: 1.0)
    let zoomed = intents.filter { $0.targetScale > 1.01 }
    XCTAssertTrue(zoomed.isEmpty)
  }

  func testTypingActivityProducesNoZoomIntentByDefault() {
    let activities = [
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.58, 0.9)),
        startSeconds: 1.0,
        endSeconds: 2.0,
        anchor: simd_double2(0.58, 0.9)),
    ]

    let intents = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 4.0)

    XCTAssertTrue(intents.isEmpty)
  }

  func testTypingIntentTargetsLowerInputRegion() {
    var config = ZoomIntentPlanner.Config()
    config.enableTypingZoom = true
    let activities = [
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.58, 0.9)),
        startSeconds: 1.0,
        endSeconds: 2.0,
        anchor: simd_double2(0.58, 0.9)),
    ]

    let intents = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 4.0,
      config: config)

    XCTAssertEqual(intents.count, 1)
    XCTAssertGreaterThan(intents[0].targetScale, 1.05)
    XCTAssertLessThanOrEqual(intents[0].targetScale, 1.55)
    XCTAssertGreaterThan(intents[0].targetAnchor.y, 0.55)
    XCTAssertLessThan(intents[0].targetAnchor.y, 0.70)
    XCTAssertGreaterThan(intents[0].urgency, 0.5)
  }

  func testTypingBurstProducesLowerInputTargetBeforeZoomIntent() {
    var config = ZoomIntentPlanner.Config()
    config.enableTypingZoom = true
    let activities = [
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.58, 0.9)),
        startSeconds: 1.0,
        endSeconds: 2.0,
        anchor: simd_double2(0.58, 0.9)),
    ]

    let targets = ZoomIntentPlanner.planTargets(
      activities: activities,
      durationSeconds: 4.0,
      config: config)

    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(targets[0].kind, .typingTarget)
    XCTAssertEqual(targets[0].anchor.y, 0.90, accuracy: 0.0001)
    XCTAssertGreaterThan(targets[0].bounds.height, 0.1)
  }

  func testTypingBurstProducesUpperSearchTarget() {
    var config = ZoomIntentPlanner.Config()
    config.enableTypingZoom = true
    let activities = [
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.60, 0.82)),
        startSeconds: 1.0,
        endSeconds: 2.0,
        anchor: simd_double2(0.60, 0.82)),
    ]

    let target = ZoomIntentPlanner.planTargets(
      activities: activities,
      durationSeconds: 4.0,
      config: config
    )[0]
    let intent = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 4.0,
      config: config
    )[0]

    XCTAssertEqual(target.kind, .typingTarget)
    XCTAssertGreaterThan(target.anchor.y, 0.74)
    XCTAssertLessThanOrEqual(intent.targetScale, 1.55)
    XCTAssertGreaterThan(intent.targetScale, 1.20)
  }

  func testTypingBurstProducesBottomInputTarget() {
    var config = ZoomIntentPlanner.Config()
    config.enableTypingZoom = true
    let activities = [
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.58, 0.16)),
        startSeconds: 1.0,
        endSeconds: 2.0,
        anchor: simd_double2(0.58, 0.16)),
    ]

    let target = ZoomIntentPlanner.planTargets(
      activities: activities,
      durationSeconds: 4.0,
      config: config
    )[0]
    let intent = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 4.0,
      config: config
    )[0]

    XCTAssertEqual(target.kind, .typingTarget)
    XCTAssertLessThan(target.anchor.y, 0.30)
    XCTAssertLessThanOrEqual(intent.targetScale, 1.55)
    XCTAssertGreaterThan(intent.targetScale, 1.20)
  }

  func testClickIntentWinsOverIdleTarget() {
    let activities = [
      ActivitySpan(
        activity: .idle,
        startSeconds: 0.0,
        endSeconds: 3.0,
        anchor: simd_double2(0.52, 0.52)),
      ActivitySpan(
        activity: .clicking(anchor: simd_double2(0.22, 0.34)),
        startSeconds: 1.0,
        endSeconds: 1.08,
        anchor: simd_double2(0.22, 0.34)),
    ]

    let intents = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 4.0)

    XCTAssertTrue(intents.contains { intent in
      let halfVisibleWidth = 0.5 / intent.targetScale
      let halfVisibleHeight = 0.5 / intent.targetScale
      return intent.urgency > 0.85 &&
      0.22 >= intent.targetAnchor.x - halfVisibleWidth - 0.02 &&
      0.22 <= intent.targetAnchor.x + halfVisibleWidth + 0.02 &&
      0.34 >= intent.targetAnchor.y - halfVisibleHeight - 0.02 &&
      0.34 <= intent.targetAnchor.y + halfVisibleHeight + 0.02
    })
  }

  func testShotPlanMergesSmallNearbyCursorMovements() {
    var config = ZoomIntentPlanner.Config()
    config.enableTypingZoom = true
    let activities = [
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.58, 0.86)),
        startSeconds: 1.0,
        endSeconds: 1.45,
        anchor: simd_double2(0.58, 0.86)),
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.61, 0.87)),
        startSeconds: 1.62,
        endSeconds: 2.0,
        anchor: simd_double2(0.61, 0.87)),
    ]

    let shots = ZoomIntentPlanner.planShots(
      activities: activities,
      durationSeconds: 4.0,
      config: config).shots

    XCTAssertEqual(shots.count, 1)
    XCTAssertEqual(shots[0].target.kind, .typingTarget)
    XCTAssertGreaterThanOrEqual(shots[0].durationSeconds, 0.8)
  }

  func testShotPlanKeepsClickAndResultAsOneHold() {
    let activities = [
      ActivitySpan(
        activity: .clicking(anchor: simd_double2(0.48, 0.42)),
        startSeconds: 1.0,
        endSeconds: 1.15,
        anchor: simd_double2(0.48, 0.42)),
    ]

    let shots = ZoomIntentPlanner.planShots(
      activities: activities,
      durationSeconds: 6.0).shots

    XCTAssertEqual(shots.count, 1)
    XCTAssertLessThanOrEqual(shots[0].startSeconds, 1.0)
    XCTAssertGreaterThan(shots[0].endSeconds, 1.9)
  }

  func testLowerEdgeTargetStaysVisibleAfterClamp() {
    var config = ZoomIntentPlanner.Config()
    config.enableTypingZoom = true
    let activities = [
      ActivitySpan(
        activity: .typing(anchor: simd_double2(0.62, 0.96)),
        startSeconds: 1.0,
        endSeconds: 2.0,
        anchor: simd_double2(0.62, 0.96)),
    ]

    let intent = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 4.0,
      config: config
    )[0]
    let halfVisibleHeight = 0.5 / intent.targetScale

    XCTAssertLessThanOrEqual(0.96, intent.targetAnchor.y + halfVisibleHeight + 0.02)
    XCTAssertGreaterThan(intent.targetAnchor.y, 0.55)
  }

  // MARK: - SpringDamperCamera

  func testCameraConvergesToTarget() {
    let intents = [
      ZoomIntent(
        startSeconds: 0, endSeconds: 5,
        targetScale: 1.5,
        targetAnchor: simd_double2(0.3, 0.4),
        urgency: 0.5),
    ]
    let samples = (0..<300).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0, x: 0.3, y: 0.4)
    }
    let frames = SpringDamperCamera.simulate(
      intents: intents, cursorSamples: samples, durationSeconds: 5.0)
    guard let last = frames.last else {
      XCTFail("No frames generated")
      return
    }
    XCTAssertEqual(last.scale, 1.5, accuracy: 0.15)
    XCTAssertEqual(last.position.x, 0.3, accuracy: 0.05)
    XCTAssertEqual(last.position.y, 0.4, accuracy: 0.05)
  }

  func testCameraReturnsToBaseAfterIntent() {
    let intents = [
      ZoomIntent(
        startSeconds: 0.5, endSeconds: 1.5,
        targetScale: 1.6,
        targetAnchor: simd_double2(0.3, 0.4),
        urgency: 0.7),
    ]
    let samples = (0..<300).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0, x: 0.5, y: 0.5)
    }
    let frames = SpringDamperCamera.simulate(
      intents: intents, cursorSamples: samples, durationSeconds: 5.0)
    guard let last = frames.last else {
      XCTFail("No frames generated")
      return
    }
    XCTAssertEqual(last.scale, 1.0, accuracy: 0.1)
  }

  func testCameraDoesNotFollowCursorWithoutIntent() {
    let samples = (0..<180).map { i in
      let t = Double(i) / 60.0
      return RecordingProject.CursorSample(
        timeSeconds: t,
        x: 0.10 + min(1.0, t / 3.0) * 0.80,
        y: 0.82)
    }

    let frames = SpringDamperCamera.simulate(
      intents: [],
      cursorSamples: samples,
      durationSeconds: 3.0)
    guard let last = frames.last else {
      XCTFail("No frames generated")
      return
    }

    XCTAssertEqual(last.scale, 1.0, accuracy: 0.02)
    XCTAssertLessThan(abs(last.position.x - 0.5), abs(last.position.x - 0.9))
    XCTAssertLessThan(abs(last.position.y - 0.5), abs(last.position.y - 0.82))
  }

  func testCameraDeadbandSuppressesTinyTargetShifts() {
    let samples = (0..<180).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.5,
        y: 0.5)
    }
    var config = SpringDamperCamera.Config()
    config.positionDeadband = 0.03
    config.scaleDeadband = 0.05
    let baseIntent = [
      ZoomIntent(
        startSeconds: 0,
        endSeconds: 3,
        targetScale: 1.5,
        targetAnchor: simd_double2(0.5, 0.5),
        urgency: 0.6),
    ]
    let shiftedIntent = [
      ZoomIntent(
        startSeconds: 0,
        endSeconds: 1.5,
        targetScale: 1.5,
        targetAnchor: simd_double2(0.5, 0.5),
        urgency: 0.6),
      ZoomIntent(
        startSeconds: 1.5,
        endSeconds: 3,
        targetScale: 1.51,
        targetAnchor: simd_double2(0.508, 0.506),
        urgency: 0.6),
    ]

    let baseFrames = SpringDamperCamera.simulate(
      intents: baseIntent,
      cursorSamples: samples,
      durationSeconds: 3.0,
      config: config)
    let shiftedFrames = SpringDamperCamera.simulate(
      intents: shiftedIntent,
      cursorSamples: samples,
      durationSeconds: 3.0,
      config: config)
    guard let baseLast = baseFrames.last, let shiftedLast = shiftedFrames.last else {
      XCTFail("No frames generated")
      return
    }

    XCTAssertLessThan(simd_distance(baseLast.position, shiftedLast.position), 0.006)
    XCTAssertEqual(baseLast.scale, shiftedLast.scale, accuracy: 0.01)
  }

  func testCameraReturnDelayHoldsLastIntentAfterIntentEnds() {
    let intents = [
      ZoomIntent(
        startSeconds: 0.2,
        endSeconds: 1.2,
        targetScale: 1.6,
        targetAnchor: simd_double2(0.35, 0.4),
        urgency: 0.8),
    ]
    let samples = (0..<180).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.35,
        y: 0.4)
    }

    let delayedFrames = SpringDamperCamera.simulate(
      intents: intents,
      cursorSamples: samples,
      durationSeconds: 2.0)
    var immediateConfig = SpringDamperCamera.Config()
    immediateConfig.noIntentReturnDelaySeconds = 0
    let immediateFrames = SpringDamperCamera.simulate(
      intents: intents,
      cursorSamples: samples,
      durationSeconds: 2.0,
      config: immediateConfig)

    let delayedHeld = delayedFrames.min { abs($0.timeSeconds - 1.35) < abs($1.timeSeconds - 1.35) }
    let immediateHeld = immediateFrames.min { abs($0.timeSeconds - 1.35) < abs($1.timeSeconds - 1.35) }
    let delayedReturned = delayedFrames.min { abs($0.timeSeconds - 1.8) < abs($1.timeSeconds - 1.8) }

    XCTAssertGreaterThan(delayedHeld?.scale ?? 0, immediateHeld?.scale ?? 0)
    XCTAssertLessThanOrEqual(delayedReturned?.scale ?? 2, (delayedHeld?.scale ?? 0) + 1e-4)
  }

  func testCameraFavorsIntentTargetOverCursorDuringTyping() {
    let intents = [
      ZoomIntent(
        startSeconds: 0.5,
        endSeconds: 2.8,
        targetScale: 1.72,
        targetAnchor: simd_double2(0.62, 0.68),
        urgency: 0.9),
    ]
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.30,
        y: 0.30)
    }

    let frames = SpringDamperCamera.simulate(
      intents: intents,
      cursorSamples: samples,
      durationSeconds: 4.0)
    let focused = frames.min { abs($0.timeSeconds - 2.0) < abs($1.timeSeconds - 2.0) }

    XCTAssertGreaterThan(focused?.position.x ?? 0, 0.55)
    XCTAssertGreaterThan(focused?.position.y ?? 0, 0.60)
    XCTAssertGreaterThan(focused?.scale ?? 0, 1.55)
  }

  func testClickHoldDoesNotImmediatelyReturnToBaseScale() {
    let intents = [
      ZoomIntent(
        startSeconds: 0.9,
        endSeconds: 2.2,
        targetScale: 1.72,
        targetAnchor: simd_double2(0.4, 0.45),
        urgency: 0.9),
    ]
    let samples = (0..<240).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.4,
        y: 0.45)
    }

    let frames = SpringDamperCamera.simulate(
      intents: intents,
      cursorSamples: samples,
      durationSeconds: 4.0)
    let held = frames.min { abs($0.timeSeconds - 1.8) < abs($1.timeSeconds - 1.8) }

    XCTAssertGreaterThan(held?.scale ?? 0, 1.45)
  }

  func testClickPlannerKeepsResultHoldAfterClick() {
    let activities = [
      ActivitySpan(
        activity: .clicking(anchor: simd_double2(0.4, 0.45)),
        startSeconds: 0.9,
        endSeconds: 1.0,
        anchor: simd_double2(0.4, 0.45)),
    ]

    let intents = ZoomIntentPlanner.plan(
      activities: activities,
      durationSeconds: 4.0)
    XCTAssertFalse(intents.isEmpty)
    XCTAssertTrue(intents.contains { $0.targetKind == .clickTarget && $0.endSeconds > 2.0 })

    let samples = (0..<240).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.4,
        y: 0.45)
    }
    let frames = SpringDamperCamera.simulate(
      intents: intents,
      cursorSamples: samples,
      durationSeconds: 4.0)
    let held = frames.min { abs($0.timeSeconds - 1.9) < abs($1.timeSeconds - 1.9) }

    XCTAssertGreaterThan(held?.scale ?? 0, 1.08)
  }

  func testCameraScaleStaysClamped() {
    let intents = [
      ZoomIntent(
        startSeconds: 0, endSeconds: 2,
        targetScale: 5.0,
        targetAnchor: simd_double2(0.5, 0.5),
        urgency: 1.0),
    ]
    let samples = (0..<120).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0, x: 0.5, y: 0.5)
    }
    let frames = SpringDamperCamera.simulate(
      intents: intents, cursorSamples: samples, durationSeconds: 2.0)
    for frame in frames {
      XCTAssertLessThanOrEqual(frame.scale, 3.0)
      XCTAssertGreaterThanOrEqual(frame.scale, 1.0)
    }
  }

  // MARK: - CameraTrack

  func testTrackProducesKeyframes() {
    let frames = (0..<600).map { i -> CameraFrame in
      let t = Double(i) / 120.0
      let scale = t < 1.0 ? 1.0 : (t < 3.0 ? 1.5 : 1.0)
      return CameraFrame(
        timeSeconds: t,
        position: simd_double2(0.4, 0.5),
        scale: scale)
    }
    let track = CameraTrack(frames: frames, durationSeconds: 5.0)
    let keyframes = track.toZoomKeyframes()
    XCTAssertFalse(keyframes.isEmpty)
    for kf in keyframes {
      XCTAssertGreaterThanOrEqual(kf.scale, 1.0)
      XCTAssertLessThanOrEqual(kf.scale, 3.0)
      XCTAssertGreaterThanOrEqual(kf.anchorX, 0)
      XCTAssertLessThanOrEqual(kf.anchorX, 1)
    }
  }

  func testTrackMergesNearbyZoomIslands() {
    let frames = (0..<600).map { i -> CameraFrame in
      let t = Double(i) / 120.0
      let scale = (t >= 0.4 && t <= 1.1) || (t >= 2.6 && t <= 3.4) ? 1.42 : 1.0
      let anchor = t < 2.0 ? simd_double2(0.42, 0.50) : simd_double2(0.48, 0.52)
      return CameraFrame(
        timeSeconds: t,
        position: anchor,
        scale: scale)
    }

    let track = CameraTrack(frames: frames, durationSeconds: 5.0)
    let segments = track.toZoomSegments()

    XCTAssertEqual(segments.count, 1)
    XCTAssertLessThanOrEqual(segments[0].startSeconds, 1.1)
    XCTAssertGreaterThanOrEqual(segments[0].endSeconds, 2.6)
  }

  func testMotionPlanInterpolatesAndClampsByCompositionTime() {
    let plan = AutoZoomMotionPlan(frames: [
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: 1.0,
        anchorX: 0.2,
        anchorY: 0.3,
        scale: 1.2),
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: 2.0,
        anchorX: 0.6,
        anchorY: 0.7,
        scale: 1.8),
    ])

    guard let before = plan.state(at: 0.5),
      let mid = plan.state(at: 1.5),
      let after = plan.state(at: 2.5)
    else {
      XCTFail("Motion plan should produce states for non-empty frames")
      return
    }

    XCTAssertEqual(before.timeSeconds, 0.5)
    XCTAssertEqual(before.anchorX, 0.2, accuracy: 0.0001)
    XCTAssertEqual(before.scale, 1.2, accuracy: 0.0001)

    XCTAssertEqual(mid.anchorX, 0.4, accuracy: 0.0001)
    XCTAssertEqual(mid.anchorY, 0.5, accuracy: 0.0001)
    XCTAssertEqual(mid.scale, 1.5, accuracy: 0.0001)

    XCTAssertEqual(after.timeSeconds, 2.5)
    XCTAssertEqual(after.anchorX, 0.6, accuracy: 0.0001)
    XCTAssertEqual(after.scale, 1.8, accuracy: 0.0001)
  }

  func testMotionPlanSmoothingSuppressesTinyAnchorAndScaleJitter() {
    let frameTime = 1.0 / 60.0
    let plan = AutoZoomMotionPlan(frames: [
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: 0.0,
        anchorX: 0.5,
        anchorY: 0.5,
        scale: 1.5),
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: frameTime,
        anchorX: 0.503,
        anchorY: 0.502,
        scale: 1.503),
    ])

    guard let smoothed = plan.state(at: frameTime) else {
      XCTFail("Motion plan should produce a smoothed state")
      return
    }

    XCTAssertEqual(smoothed.anchorX, 0.5, accuracy: 0.0001)
    XCTAssertEqual(smoothed.anchorY, 0.5, accuracy: 0.0001)
    XCTAssertEqual(smoothed.scale, 1.5, accuracy: 0.0001)
  }

  func testMotionPlanSmoothingBlendsSmallContinuousChanges() {
    let frameTime = 1.0 / 60.0
    let plan = AutoZoomMotionPlan(frames: [
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: 0.0,
        anchorX: 0.5,
        anchorY: 0.5,
        scale: 1.5),
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: frameTime,
        anchorX: 0.51,
        anchorY: 0.5,
        scale: 1.52),
    ])

    guard let smoothed = plan.state(at: frameTime) else {
      XCTFail("Motion plan should produce a smoothed state")
      return
    }

    XCTAssertEqual(smoothed.anchorX, 0.5035, accuracy: 0.0001)
    XCTAssertEqual(smoothed.anchorY, 0.5, accuracy: 0.0001)
    XCTAssertEqual(smoothed.scale, 1.507, accuracy: 0.0001)
  }

  func testMotionPlanSmoothingResetsAfterFrameGap() {
    let plan = AutoZoomMotionPlan(frames: [
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: 0.0,
        anchorX: 0.2,
        anchorY: 0.3,
        scale: 1.2),
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: 0.2,
        anchorX: 0.23,
        anchorY: 0.32,
        scale: 1.23),
    ])

    guard let state = plan.state(at: 0.2) else {
      XCTFail("Motion plan should produce a state after a frame gap")
      return
    }

    XCTAssertEqual(state.anchorX, 0.23, accuracy: 0.0001)
    XCTAssertEqual(state.anchorY, 0.32, accuracy: 0.0001)
    XCTAssertEqual(state.scale, 1.23, accuracy: 0.0001)
  }

  func testMotionPlanSmoothingPreservesLargeMoves() {
    let frameTime = 1.0 / 60.0
    let plan = AutoZoomMotionPlan(frames: [
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: 0.0,
        anchorX: 0.25,
        anchorY: 0.3,
        scale: 1.2),
      RecordingProject.AutoZoomMotionFrame(
        timeSeconds: frameTime,
        anchorX: 0.65,
        anchorY: 0.7,
        scale: 1.8),
    ])

    guard let state = plan.state(at: frameTime) else {
      XCTFail("Motion plan should preserve large motion states")
      return
    }

    XCTAssertEqual(state.anchorX, 0.65, accuracy: 0.0001)
    XCTAssertEqual(state.anchorY, 0.7, accuracy: 0.0001)
    XCTAssertEqual(state.scale, 1.8, accuracy: 0.0001)
  }

  // MARK: - Full pipeline

  func testFullPipelineProducesOutput() {
    var samples: [RecordingProject.CursorSample] = []
    for i in 0..<600 {
      let t = Double(i) / 60.0
      let x: Double
      if t < 3 {
        x = 0.3
      } else if t < 5 {
        x = 0.3 + (t - 3) * 0.2
      } else {
        x = 0.7
      }
      samples.append(RecordingProject.CursorSample(
        timeSeconds: t, x: x, y: 0.5))
    }
    let events = [
      RecordingProject.InputEvent(
        timeSeconds: 2.0, kind: .mouseDown,
        x: 0.3, y: 0.5, modifierFlagsRaw: 0),
      RecordingProject.InputEvent(
        timeSeconds: 2.05, kind: .mouseUp,
        x: 0.3, y: 0.5, modifierFlagsRaw: 0),
    ]
    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 10.0)
    XCTAssertFalse(result.activities.isEmpty)
    XCTAssertFalse(result.track.frames.isEmpty)
    XCTAssertFalse(result.zoomFrames.isEmpty)
  }

  func testClickPipelineUsesProductDemoReadableZoomScale() {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.36,
        y: 0.42)
    }
    let events = [
      RecordingProject.InputEvent(
        timeSeconds: 1.2,
        kind: .mouseDown,
        x: 0.36,
        y: 0.42,
        modifierFlagsRaw: 0),
    ]

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 6.0)

    XCTAssertFalse(result.zoomSegments.isEmpty)
    XCTAssertGreaterThanOrEqual(result.zoomSegments.map(\.scale).max() ?? 0, 1.08)
    XCTAssertTrue(result.zoomSegments.allSatisfy { $0.scale <= 1.35 })
    XCTAssertTrue(result.zoomSegments.allSatisfy { $0.mode == .auto })
  }

  func testFocusRegionMakesSmallClickTargetReadable() {
    let samples = (0..<420).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.24,
        y: 0.32)
    }
    let events = [
      RecordingProject.InputEvent(
        timeSeconds: 1.4,
        kind: .mouseDown,
        x: 0.24,
        y: 0.32,
        modifierFlagsRaw: 0),
    ]
    let regions = [
      FocusRegion(
        startSeconds: 1.32,
        endSeconds: 2.2,
        bounds: CGRect(x: 0.21, y: 0.29, width: 0.08, height: 0.045),
        kind: .clickTarget,
        confidence: 0.95),
    ]

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 7.0,
      focusRegions: regions)

    XCTAssertFalse(result.zoomSegments.isEmpty)
    XCTAssertGreaterThanOrEqual(result.zoomSegments.map(\.scale).max() ?? 0, 1.08)
    XCTAssertTrue(result.zoomSegments.allSatisfy { $0.scale <= 1.35 })
    XCTAssertEqual(result.focusRegions, regions)
  }

  func testNavigationAndScrollingDoNotProduceZoomSegments() {
    var samples: [RecordingProject.CursorSample] = []
    for i in 0..<240 {
      let t = Double(i) / 60.0
      let phase = t.truncatingRemainder(dividingBy: 1.0)
      let x = phase < 0.5
        ? 0.1 + phase * 1.6
        : 0.9 - (phase - 0.5) * 1.6
      samples.append(RecordingProject.CursorSample(
        timeSeconds: t,
        x: x,
        y: 0.5))
    }

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: [],
      durationSeconds: 4.0)

    XCTAssertTrue(result.intents.allSatisfy { $0.targetScale <= 1.001 })
    XCTAssertTrue(result.zoomSegments.isEmpty)
  }

  func testTypingOnlyPipelineProducesNoZoomSegmentsByDefault() {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.58,
        y: 0.9)
    }
    let events = (0..<8).map { i in
      RecordingProject.InputEvent(
        timeSeconds: 1.0 + Double(i) * 0.12,
        kind: .keyDown,
        keyCode: UInt16(i),
        modifierFlagsRaw: 0)
    }

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 6.0)

    XCTAssertTrue(result.activities.contains {
      if case .typing = $0.activity { return true }
      return false
    })
    XCTAssertTrue(result.intents.isEmpty)
    XCTAssertTrue(result.zoomSegments.isEmpty)
  }

  func testProductDemoPipelineProducesTypingZoomSegment() {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.58,
        y: 0.9)
    }
    let events = (0..<8).map { i in
      RecordingProject.InputEvent(
        timeSeconds: 1.0 + Double(i) * 0.12,
        kind: .keyDown,
        keyCode: UInt16(i),
        modifierFlagsRaw: 0)
    }

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 6.0,
      config: .productDemo)

    XCTAssertTrue(result.intents.contains { $0.targetKind == .typingTarget && $0.targetScale > 1.05 })
    XCTAssertFalse(result.zoomSegments.isEmpty)
    XCTAssertTrue(result.zoomSegments.allSatisfy { $0.mode == .auto })
  }

  func testProductDemoPipelineKeepsFastNavigationUnzoomed() {
    var samples: [RecordingProject.CursorSample] = []
    for i in 0..<240 {
      let t = Double(i) / 60.0
      let phase = t.truncatingRemainder(dividingBy: 0.8)
      let x = phase < 0.4
        ? 0.08 + phase * 2.0
        : 0.88 - (phase - 0.4) * 2.0
      samples.append(RecordingProject.CursorSample(
        timeSeconds: t,
        x: x,
        y: 0.5))
    }

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: [],
      durationSeconds: 4.0,
      config: .productDemo)

    XCTAssertTrue(result.intents.allSatisfy { $0.targetScale <= 1.001 })
    XCTAssertTrue(result.zoomSegments.isEmpty)
  }

  func testProductDemoPipelinePreservesManualOverrideOverTypingZoom() {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.58,
        y: 0.9)
    }
    let events = (0..<8).map { i in
      RecordingProject.InputEvent(
        timeSeconds: 1.0 + Double(i) * 0.12,
        kind: .keyDown,
        keyCode: UInt16(i),
        modifierFlagsRaw: 0)
    }
    let manual = [
      RecordingProject.ZoomKeyframe(
        startSeconds: 0.8,
        endSeconds: 2.4,
        scale: 1.8,
        anchorX: 0.7,
        anchorY: 0.3),
    ]

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 6.0,
      existingManualKeyframes: manual,
      config: .productDemo)

    XCTAssertFalse(result.intents.contains { $0.targetKind == .typingTarget })
    XCTAssertTrue(result.zoomSegments.allSatisfy { segment in
      max(segment.startSeconds, manual[0].startSeconds) >= min(segment.endSeconds, manual[0].endSeconds)
    })
    XCTAssertTrue(result.zoomFrames.contains { $0.id == manual[0].id })
  }

  func testNearbyClicksDoNotCreateExcessiveSegments() {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.58,
        y: 0.36)
    }
    let events = [
      RecordingProject.InputEvent(timeSeconds: 1.0, kind: .mouseDown, x: 0.58, y: 0.36, modifierFlagsRaw: 0),
      RecordingProject.InputEvent(timeSeconds: 1.28, kind: .mouseDown, x: 0.58, y: 0.36, modifierFlagsRaw: 0),
      RecordingProject.InputEvent(timeSeconds: 1.56, kind: .mouseDown, x: 0.58, y: 0.36, modifierFlagsRaw: 0),
    ]

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 6.0)

    XCTAssertLessThanOrEqual(result.zoomSegments.count, 2)
  }

  func testResultChangeRegionCanHoldAndPanAfterClick() {
    var config = AutoZoomPipeline.Config()
    config.intent.enableResultChangePan = true
    let samples = (0..<420).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.34,
        y: 0.48)
    }
    let events = [
      RecordingProject.InputEvent(timeSeconds: 1.0, kind: .mouseDown, x: 0.34, y: 0.48, modifierFlagsRaw: 0),
    ]
    let regions = [
      FocusRegion(
        startSeconds: 1.15,
        endSeconds: 2.0,
        bounds: CGRect(x: 0.62, y: 0.22, width: 0.24, height: 0.2),
        kind: .resultChange,
        confidence: 0.86),
    ]

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 7.0,
      focusRegions: regions,
      config: config)

    XCTAssertFalse(result.intents.isEmpty)
    let resultIntent = result.intents.last { $0.targetKind == .resultTarget }
    XCTAssertGreaterThan(resultIntent?.endSeconds ?? 0, 2.6)
    XCTAssertGreaterThan(resultIntent?.targetAnchor.x ?? 0, 0.55)
    XCTAssertLessThan(resultIntent?.targetAnchor.y ?? 1, 0.45)
    XCTAssertLessThanOrEqual(resultIntent?.targetScale ?? 0, 1.35)
  }

  func testResultChangeRegionDoesNotPanByDefault() {
    let samples = (0..<420).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.34,
        y: 0.48)
    }
    let events = [
      RecordingProject.InputEvent(timeSeconds: 1.0, kind: .mouseDown, x: 0.34, y: 0.48, modifierFlagsRaw: 0),
    ]
    let regions = [
      FocusRegion(
        startSeconds: 1.15,
        endSeconds: 2.0,
        bounds: CGRect(x: 0.62, y: 0.22, width: 0.24, height: 0.2),
        kind: .resultChange,
        confidence: 0.86),
    ]

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 7.0,
      focusRegions: regions)

    XCTAssertFalse(result.intents.isEmpty)
    XCTAssertTrue(result.intents.contains { $0.targetKind == .clickTarget })
    XCTAssertFalse(result.intents.contains { $0.targetAnchor.x > 0.55 && $0.targetAnchor.y < 0.45 })
  }

  func testManualKeyframesArePreserved() {
    let samples = (0..<600).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0, x: 0.5, y: 0.5)
    }
    let manual = [
      RecordingProject.ZoomKeyframe(
        startSeconds: 2.0, endSeconds: 4.0,
        scale: 2.0, anchorX: 0.8, anchorY: 0.2),
    ]
    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: [],
      durationSeconds: 10.0,
      existingManualKeyframes: manual)
    let hasManual = result.zoomFrames.contains {
      abs($0.startSeconds - 2.0) < 0.01 && abs($0.scale - 2.0) < 0.01
    }
    XCTAssertTrue(hasManual, "Manual keyframe should be preserved in output")
  }

  func testManualKeyframesSuppressOverlappingAutoSegments() {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.42,
        y: 0.44)
    }
    let events = [
      RecordingProject.InputEvent(
        timeSeconds: 2.2,
        kind: .mouseDown,
        x: 0.42,
        y: 0.44,
        modifierFlagsRaw: 0),
    ]
    let manual = [
      RecordingProject.ZoomKeyframe(
        startSeconds: 1.8,
        endSeconds: 2.8,
        scale: 1.8,
        anchorX: 0.7,
        anchorY: 0.3),
    ]

    let result = AutoZoomPipeline.generate(
      cursorSamples: samples,
      inputEvents: events,
      durationSeconds: 6.0,
      existingManualKeyframes: manual)

    XCTAssertTrue(result.zoomSegments.allSatisfy { segment in
      max(segment.startSeconds, manual[0].startSeconds) >= min(segment.endSeconds, manual[0].endSeconds)
    })
    XCTAssertTrue(result.zoomFrames.contains { $0.id == manual[0].id })
  }

  func testGenerateFromProjectUsesInjectedFocusRegionDetector() async {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.51,
        y: 0.42)
    }
    let events = [
      RecordingProject.InputEvent(
        timeSeconds: 1.25,
        kind: .mouseDown,
        x: 0.51,
        y: 0.42,
        modifierFlagsRaw: 0),
    ]
    let regions = [
      FocusRegion(
        startSeconds: 1.2,
        endSeconds: 2.2,
        bounds: CGRect(x: 0.47, y: 0.38, width: 0.08, height: 0.05),
        kind: .clickTarget,
        confidence: 0.9),
    ]
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Focus",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: URL(fileURLWithPath: "/tmp/focus.mov"),
      cursorSamples: samples,
      exportPreset: .p1080p60,
      stylePreset: .cursorFocus,
      inputEvents: events
    )

    let result = await AutoZoomPipeline.generateWithFocusDetection(
      from: project,
      assetDurationSeconds: 6.0,
      focusRegionDetector: FakeFocusRegionDetector(regions: regions))

    XCTAssertEqual(result.focusRegions, regions)
    XCTAssertFalse(result.zoomSegments.isEmpty)
  }

  func testAutoZoomAnalysisStoresDenseMotionFramesAndInvalidatesBySignature() async {
    let samples = (0..<360).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.48,
        y: 0.44)
    }
    let events = [
      RecordingProject.InputEvent(
        timeSeconds: 1.0,
        kind: .mouseDown,
        x: 0.48,
        y: 0.44,
        modifierFlagsRaw: 0),
    ]
    let project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Dense Motion",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: URL(fileURLWithPath: "/tmp/dense-motion.mov"),
      cursorSamples: samples,
      exportPreset: .p1080p60,
      stylePreset: .cursorFocus,
      inputEvents: events
    )

    let analysis = await AutoZoomAnalysisService.makeAnalysis(
      project: project,
      assetDurationSeconds: 6.0,
      focusRegionDetector: FakeFocusRegionDetector(regions: [])
    )

    XCTAssertGreaterThanOrEqual(analysis.motionFrames.count, 6 * 100)
    XCTAssertFalse(analysis.editableSegments.isEmpty)
    XCTAssertTrue(analysis.matches(
      sourceSignature: AutoZoomAnalysisService.sourceSignature(project: project, assetDurationSeconds: 6.0),
      assetDurationSeconds: 6.0
    ))
    XCTAssertFalse(analysis.matches(
      sourceSignature: AutoZoomAnalysisService.sourceSignature(project: project, assetDurationSeconds: 7.0),
      assetDurationSeconds: 7.0
    ))
  }

  func testAutoSegmentsDoNotSuppressPersistedMotionPlan() async {
    let samples = (0..<240).map { i in
      RecordingProject.CursorSample(
        timeSeconds: Double(i) / 60.0,
        x: 0.42,
        y: 0.38)
    }
    var project = RecordingProject(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 0),
      title: "Auto Segment Motion",
      source: .init(kind: .window, displayID: nil, windowID: 1),
      mediaURL: URL(fileURLWithPath: "/tmp/auto-segment-motion.mov"),
      cursorSamples: samples,
      exportPreset: .p1080p60,
      stylePreset: .cursorFocus,
      zoomSegments: [
        RecordingProject.ZoomSegment(
          startSeconds: 0.8,
          endSeconds: 2.0,
          mode: .auto,
          scale: 1.4,
          anchorX: 0.42,
          anchorY: 0.38),
      ],
      inputEvents: [
        RecordingProject.InputEvent(
          timeSeconds: 1.0,
          kind: .mouseDown,
          x: 0.42,
          y: 0.38,
          modifierFlagsRaw: 0),
      ]
    )
    project.autoZoomAnalysis = await AutoZoomAnalysisService.makeAnalysis(
      project: project,
      assetDurationSeconds: 4.0,
      focusRegionDetector: FakeFocusRegionDetector(regions: [])
    )

    let resolved = AutoZoomMotionResolver.resolve(
      project: project,
      assetDurationSeconds: 4.0,
      exportStartSeconds: 0,
      exportEndSeconds: 4.0
    )

    XCTAssertEqual(resolved.source, AutoZoomMotionResolution.Source.persisted)
    XCTAssertNotNil(resolved.motionPlan)
    XCTAssertTrue(resolved.zoomKeyframes.isEmpty)
  }
}

private struct FakeFocusRegionDetector: FocusRegionDetecting {
  var regions: [FocusRegion]

  func detectFocusRegions(
    project: RecordingProject,
    assetDurationSeconds: Double
  ) async -> [FocusRegion] {
    regions
  }
}
