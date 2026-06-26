import AVFoundation
import Foundation
import Observation

/// Timeline undo/redo for Review; persists via `ProjectStore.saveCurrent()` when finalizing a gesture.
@MainActor
final class ReviewTimelineUndoController: NSObject {
  let undoManager = UndoManager()
  weak var projectStore: ProjectStore?

  func finalizeZoomKeyframesUndo(undoLabel: String, before: [RecordingProject.ZoomKeyframe], after: [RecordingProject.ZoomKeyframe]) {
    guard let store = projectStore else { return }
    guard before != after else {
      store.saveCurrent()
      return
    }

    undoManager.setActionName(undoLabel)
    undoManager.registerUndo(withTarget: self) { [weak self] _ in
      guard let self else { return }
      store.applyToCurrent({ $0.zoomSegments = before.map(RecordingProject.ZoomSegment.fromKeyframe) })
      store.saveCurrent()
      self.undoManager.registerUndo(withTarget: self) { [weak self] _ in
        guard self != nil else { return }
        store.applyToCurrent({ $0.zoomSegments = after.map(RecordingProject.ZoomSegment.fromKeyframe) })
        store.saveCurrent()
      }
    }
    store.saveCurrent()
  }

  /// Registers undo/redo for highlight regions; state must already be `after`.
  func finalizeHighlightRegionsUndo(undoLabel: String, before: [RecordingProject.CursorHighlightRegion], after: [RecordingProject.CursorHighlightRegion]) {
    guard let store = projectStore else { return }
    guard before != after else {
      store.saveCurrent()
      return
    }

    undoManager.setActionName(undoLabel)
    undoManager.registerUndo(withTarget: self) { [weak self] _ in
      guard let self else { return }
      store.applyToCurrent({ $0.cursorHighlightRegions = before })
      store.saveCurrent()
      self.undoManager.registerUndo(withTarget: self) { [weak self] _ in
        guard self != nil else { return }
        store.applyToCurrent({ $0.cursorHighlightRegions = after })
        store.saveCurrent()
      }
    }
    store.saveCurrent()
  }

  /// Toolbar / one-shot edits: writes `after` then registers undo back to `before`.
  func replaceZoomKeyframesWithUndo(undoLabel: String, before: [RecordingProject.ZoomKeyframe], after: [RecordingProject.ZoomKeyframe]) {
    guard let store = projectStore else { return }
    guard before != after else { return }
    store.applyToCurrent({ $0.zoomSegments = after.map(RecordingProject.ZoomSegment.fromKeyframe) }, persist: false)
    finalizeZoomKeyframesUndo(undoLabel: undoLabel, before: before, after: after)
  }

  func replaceZoomSegmentsWithUndo(
    undoLabel: String,
    before: [RecordingProject.ZoomSegment],
    after: [RecordingProject.ZoomSegment]
  ) {
    guard let store = projectStore else { return }
    guard before != after else { return }
    store.applyToCurrent({ $0.zoomSegments = after }, persist: false)
    undoManager.setActionName(undoLabel)
    undoManager.registerUndo(withTarget: self) { [weak self] _ in
      guard let self else { return }
      store.applyToCurrent({ $0.zoomSegments = before })
      store.saveCurrent()
      self.undoManager.registerUndo(withTarget: self) { [weak self] _ in
        guard self != nil else { return }
        store.applyToCurrent({ $0.zoomSegments = after })
        store.saveCurrent()
      }
    }
    store.saveCurrent()
  }

  func replaceHighlightRegionsWithUndo(undoLabel: String, before: [RecordingProject.CursorHighlightRegion], after: [RecordingProject.CursorHighlightRegion]) {
    guard let store = projectStore else { return }
    guard before != after else { return }
    store.applyToCurrent({ $0.cursorHighlightRegions = after }, persist: false)
    finalizeHighlightRegionsUndo(undoLabel: undoLabel, before: before, after: after)
  }

  func finalizeClickCuesUndo(undoLabel: String, before: [RecordingProject.CursorClickCue], after: [RecordingProject.CursorClickCue]) {
    guard let store = projectStore else { return }
    guard before != after else {
      store.saveCurrent()
      return
    }

    undoManager.setActionName(undoLabel)
    undoManager.registerUndo(withTarget: self) { [weak self] _ in
      guard let self else { return }
      store.applyToCurrent({ $0.cursorClickCues = before })
      store.saveCurrent()
      self.undoManager.registerUndo(withTarget: self) { [weak self] _ in
        guard self != nil else { return }
        store.applyToCurrent({ $0.cursorClickCues = after })
        store.saveCurrent()
      }
    }
    store.saveCurrent()
  }

  func replaceClickCuesWithUndo(undoLabel: String, before: [RecordingProject.CursorClickCue], after: [RecordingProject.CursorClickCue]) {
    guard let store = projectStore else { return }
    guard before != after else { return }
    store.applyToCurrent({ $0.cursorClickCues = after }, persist: false)
    finalizeClickCuesUndo(undoLabel: undoLabel, before: before, after: after)
  }

  /// Registers undo/redo for a whole-project mutation (clip bounds + combined tracks etc.).
  func finalizeWholeProjectUndo(undoLabel: String, before: RecordingProject, after: RecordingProject) {
    guard let store = projectStore else { return }
    guard before != after else {
      store.saveCurrent()
      return
    }

    undoManager.setActionName(undoLabel)
    undoManager.registerUndo(withTarget: self) { [weak self] _ in
      guard let self else { return }
      store.setCurrent(before)
      store.saveCurrent()
      self.undoManager.registerUndo(withTarget: self) { [weak self] _ in
        guard self != nil else { return }
        store.setCurrent(after)
        store.saveCurrent()
      }
    }
    store.setCurrent(after)
    store.saveCurrent()
  }
}

/// Drives observed seconds from `AVPlayer` for the scrubber / shortcuts.
@MainActor
@Observable
final class ReviewPlayheadTicker {
  var seconds: Double = 0
  private weak var watchedPlayer: AVPlayer?
  private var token: Any?

  func bind(player: AVPlayer?, clampDuration: Double) {
    detach()
    guard let player else { return }
    watchedPlayer = player
    let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
    token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let d = max(0.001, clampDuration)
        self.seconds = max(0, min(time.seconds, d))
      }
    }
  }

  func detach() {
    if let watchedPlayer, let token {
      watchedPlayer.removeTimeObserver(token)
    }
    token = nil
    watchedPlayer = nil
  }
}
