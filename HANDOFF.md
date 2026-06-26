# ArcShot カスタムコンポジター引き継ぎ文書

> **不変条件の正本:** [`docs/INVARIANTS.md`](docs/INVARIANTS.md) — カーソル・キャプチャ・ランチャー・書き出しの「壊してはいけないルール」

## 2025-06 安定化マイルストーン（main マージ対象）

以下は実機デバッグとテストで確定した修正。詳細は `docs/INVARIANTS.md` 各節を参照。

| 領域 | 要点 | 主要ファイル |
| --- | --- | --- |
| カーソル位置 | ウィンドウ録画は `SCStreamFrameInfo.screenRect` を優先（filter `contentRect` 単独禁止） | `RecordingCoordinator.swift`, `RecordingWriterSession.swift` |
| 書き出し権限 | サンドボックス下はコンテナ temp → security-scoped コピー | `ExportOutputAccess.swift`, `Exporter.swift` |
| ランチャー | Liquid Glass UI、3秒カウントダウン、設定ボタン | `RecordingLauncherBarDesign.swift`, `FloatingRecordingWidget.swift` |
| カウントダウン後フリーズ | `AVCaptureSession` は `commitConfiguration()` **後** に `startRunning()` | `MicrophoneCapture.swift`, `CameraMovieCapture.swift` |
| 書き出し画質 | `matchSource60` デフォルト、可変キャプチャ/書き出しビットレート、`highQualityDownsample` | `ExportPreset.swift`, `Exporter.swift`, `ArcShotVideoCompositor.swift` |

### 次の開発（他開発者へ委譲 — タスク化済み）

詳細・受け入れ条件・Issue 雛形: **[`docs/NEXT_MILESTONES.md`](NEXT_MILESTONES.md)**

| ID | 内容 |
| --- | --- |
| M7 | 書き出し構造の解析 / 作り直し (`Exporter.swift` + compositor) |
| M8 | インカメ録画 UX（現状 `CameraMovieCapture` サイドカー `.mov`） |

**2025-06 クローズ記録:** [`docs/CLOSED_MILESTONE_2025-06.md`](CLOSED_MILESTONE_2025-06.md)

---

## 完了済み: Milestone 1 — ズーム＋カーソル統合コンポジター

### 何を変えたか

旧アーキテクチャ（CAKeyframeAnimation + AVVideoCompositionCoreAnimationTool）を廃止し、`AVVideoCompositing` プロトコルのカスタム実装に置き換えた。これにより、ズーム変換とカーソル描画が同一座標系で処理され、構造的な座標ズレが解消された。

### 変更ファイル一覧

| ファイル | 操作 | 内容 |
|---------|------|------|
| `Features/Export/ArcShotVideoCompositor.swift` | **新規** | `AVVideoCompositing` 実装。Metal CIContext でフレーム毎レンダリング |
| `Features/Export/ArcShotCompositionInstruction.swift` | **新規** | `AVVideoCompositionInstructionProtocol` 準拠。セグメント毎のズーム・カーソル・エフェクト情報 |
| `Features/Export/ArcShotCompositionInstructionBuilder.swift` | **新規** | ズームキーフレーム境界でタイムライン分割、instruction 構築 |
| `Features/Export/CursorRenderer.swift` | **新規** | CGContext カーソル描画（白丸+リング+クリックパルス）、二分探索補間 |
| `Features/Export/Exporter.swift` | **変更** | `makeVideoPipeline` で `customVideoCompositorClass` を使用。旧コード（`makePostProcessingAnimationTool` 等）は残存するが未使用 |
| `Features/Capture/RecordingCoordinator.swift` | **変更** | `config.showsCursor = false` 追加、`classifyCursorShape` でカーソル形状記録 |
| `Domain/RecordingProject.swift` | **変更** | `CursorShape` enum 追加、`CursorSample.shape` フィールド追加（optional、後方互換） |
| `Domain/AutoZoom/ActivityClassifier.swift` | **変更** | `nextEventBoundary()` 追加、greedy idle/navigation span バグ修正 |

### レンダリングパイプライン（processRequest フロー）

```
sourceFrame(byTrackID:) → CVPixelBuffer
  ↓
CIImage化 → zoomTransform適用 → crop(renderSize)
  ↓
[stage有効時] 背景色 + aspect-fit card 合成
  ↓
[PiP有効時] PiPフレーム取得 → transform → composite over
  ↓
CIContext.render → outputBuffer
  ↓
[カーソル有効時] CGContext でカーソル描画（zoomedCursorPx座標）
  ↓
[フェード有効時] CGContext で黒矩形オーバーレイ
  ↓
request.finish(withComposedVideoFrame:)
```

### 座標統合の核心

```swift
let cursorPx = CGPoint(x: cx * renderSize.width, y: cy * renderSize.height)
let zoomedCursorPx = cursorPx.applying(zoomTransform)
// → ビデオと同じ zoomTransform を適用するため、座標ズレが構造的に解消
```

### ビルド・テスト状態

- 全 63 テスト通過（0 failures）
- 実機テスト（実際の録画→エクスポート）は未実施

---

## 現在の状況: M7 後のコンポジター

この節は以前、コンポジター未実装項目として text overlay、visual mask、stage 詳細を列挙していた。M7 時点ではこれらは `ArcShotVideoCompositor.processRequest` から到達する描画経路に入っている。

現在の export compositor は以下を描画する:

1. **テキスト / caption / keyboard shortcut overlay** — `instruction.textOverlays` を CoreText + CGContext で描画する。
2. **ビジュアルマスク** — blur mask は CoreImage、highlight mask は CGContext で描画する。
3. **ステージレイアウト詳細** — background、card、rounded clipping、shadow、content placement を `ArcShotRenderGeometry` ベースで描画する。

残リスクは「instruction にあるのに MP4 export で未描画」ではなく、`docs/PREVIEW_EXPORT_GAPS.md` にある preview/export raster parity と、`ArcShotVideoCompositor.swift` が大きく保守コストの高い renderer である点。

M7-04 の判断は [`docs/export/COMPOSITOR_REWRITE_SPIKE.md`](docs/export/COMPOSITOR_REWRITE_SPIKE.md) を参照。現時点では compositor 全面 rewrite は延期し、測定可能な benchmark なしに置き換えない。

---

## Milestone 2: カーソル画像アセット（次の実装候補）

### 目的
白丸+リングの汎用カーソルを、実際のカーソル形状（矢印・手・I-beam 等）の高解像度画像に置き換える。

### 実装方針
- 各 `CursorShape` に対応する PNG アセットをバンドル（@2x）
- `CursorRenderer` にアセット描画パスを追加
- ホットスポットオフセット対応（矢印は左上、十字は中央 等）
- 影・スケール対応

### 録画側は完了済み
`RecordingCoordinator.classifyCursorShape` で `NSCursor.currentSystem` からカーソル形状を分類・記録する機能は Milestone 1 で実装済み。`CursorSample.shape` にデータが入る。

---

## Milestone 3: ライブプレビュー

### 目的
エディタ画面でカスタムコンポジターを使った WYSIWYG プレビューを表示。

### 実装方針
- `AVPlayerItem` に `AVVideoComposition` + `customVideoCompositorClass` を設定
- プレビュー用の軽量レンダリングモード（解像度下げる等）を検討
- ズーム・カーソル・エフェクトの編集結果をリアルタイムで確認可能に

---

## 旧コード（削除候補）

`Exporter.swift` 内の以下メソッドは `customVideoCompositorClass` 移行後は使われていない:

- `makePostProcessingAnimationTool` — CALayer ツリー構築（カーソル・ステージ・テキスト・マスク・フェード）
- `makeZoomCompositionInstructions` — `AVMutableVideoCompositionLayerInstruction` によるズーム
- `makeCursorLayer`, `makeClickCueLayer`, `makeStageLayoutLayer` 等のヘルパー

テキストオーバーレイ・ビジュアルマスクのコンポジター内レンダリング完了後に削除可能。

---

## 技術的な注意点

1. **`customVideoCompositorClass` と `animationTool` は排他** — 両方設定すると `animationTool` は無視される。コンポジター内で全ビジュアル機能を実装する必要がある
2. **`AVVideoCompositionInstructionProtocol` の ObjC 制約** — stored property を直接プロトコル準拠にできない。`_timeRange` + computed `timeRange` パターンを使用
3. **`@unchecked Sendable`** — モダン Swift の `AVVideoCompositionInstructionProtocol` は Sendable 準拠が必要
4. **`containsTweening`** — `containsTweenedAnimation` ではない（プロトコル名に注意）
5. **`NSCursor.currentSystem`** — `currentSystemCursor` は旧名。現在のAPIは `currentSystem`
6. **`ExportVisualSettings.backgroundColorHex`** — RGB は個別プロパティではなく16進文字列で格納
