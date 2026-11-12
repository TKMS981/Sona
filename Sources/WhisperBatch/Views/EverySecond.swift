import SwiftUI

/// 1 秒ごとに描き直す表示（経過時間など）。`isActive` が false のとき（一時停止中・終了後など、値が変わらないとき）は
/// 描き直さず、今の時刻で 1 回だけ描く。
struct EverySecond<Content: View>: View {
    let isActive: Bool
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}
