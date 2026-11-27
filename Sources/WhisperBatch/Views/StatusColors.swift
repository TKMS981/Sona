import AppKit
import SwiftUI

/// 注意・エラーを文字で示すときの色。
///
/// システムの橙（#FF9500）は白の背景で 2.2:1、赤（#FF3B30）は 3.6:1、緑は 2.1:1 しかなく、小さな文字（caption）では読みにくい。
/// 文字に使うときはライトでは暗めにして、ウィンドウの背景（#ECECEC）に対しても 4.5:1 以上にする。
/// ダークではシステムの色のままで十分に読める。アイコンや淡い背景の色は、これまでどおりシステムの色を使う。
extension Color {
    /// 注意の文字（ライト #A35200: 白に 5.6:1・ウィンドウの背景に 4.7:1 / ダークはシステムの橙）
    static let warningText = Color(nsColor: NSColor(name: "SonaWarningText") { appearance in
        appearance.isDark ? .systemOrange : NSColor(srgbRed: 0.64, green: 0.32, blue: 0.0, alpha: 1)
    })

    /// エラーの文字（ライト #BF1A12: 白に 6.2:1・ウィンドウの背景に 5.3:1 / ダークはシステムの赤）
    static let errorText = Color(nsColor: NSColor(name: "SonaErrorText") { appearance in
        appearance.isDark ? .systemRed : NSColor(srgbRed: 0.75, green: 0.10, blue: 0.07, alpha: 1)
    })

    /// 完了・取得済みの文字（ライト #147526: 白に 5.8:1・ウィンドウの背景に 4.9:1 / ダークはシステムの緑）
    static let successText = Color(nsColor: NSColor(name: "SonaSuccessText") { appearance in
        appearance.isDark ? .systemGreen : NSColor(srgbRed: 0.08, green: 0.46, blue: 0.15, alpha: 1)
    })
}

/// `.foregroundStyle(.warningText)` のように書けるようにする
extension ShapeStyle where Self == Color {
    static var warningText: Color { Color.warningText }
    static var errorText: Color { Color.errorText }
    static var successText: Color { Color.successText }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}
