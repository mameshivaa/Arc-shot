import SwiftUI

/// Shared countdown duration for launcher (`FloatingRecordingWidget`) and dev `RecordView`.
/// Change only here — do not duplicate magic numbers elsewhere.
enum RecordingCountdown {
  static let seconds = 3
}

/// 収録開始前のフルスクリーンカウントダウン（メインウィンドウのキャプチャ画面と共通）。
struct CountdownOverlay: View {
  @Environment(AppLanguageStore.self) private var languageStore
  let secondsRemaining: Int

  var body: some View {
    ZStack {
      Color.black.opacity(0.54)
        .ignoresSafeArea()

      Text("\(secondsRemaining)")
        .font(.system(size: 132, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.94))
        .shadow(color: .black.opacity(0.52), radius: 28, x: 0, y: 12)

      Text("まもなく収録開始")
        .font(.system(size: 18, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.9))
        .offset(y: 112)
        .allowsHitTesting(false)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(languageStore.localizedFormat("カウントダウン %d 秒後に収録を開始します", secondsRemaining))
  }
}
