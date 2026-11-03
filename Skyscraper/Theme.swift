//
//  Theme.swift
//  Skyscraper
//
//  アール・デコ配色と、その切り替え。
//
//  以前は ContentView.swift の冒頭に enum Deco が static let で
//  色を直に持っていた。配色を選べるようにするため、色の実体は
//  DecoPalette (配色一式の表) に移し、Deco の各色は
//  「今選ばれている配色の表を引く」計算プロパティに変えた。
//  呼び出し側 (Deco.gold など) の書き方は一文字も変わらない。
//
//  切り替えた瞬間に全ての窓が塗り直されるのは Observation の働き。
//  DecoThemeStore を @Observable にしてあるので、body の中で
//  Deco.gold を読んだ View は、知らないうちに theme を見張っている。
//  @ObservedObject を全ての View に配って回る必要は無い。
//
//  例外は SwiftUI の外で塗っているもの:
//   - AppKit の入力欄 (アドレスバー・ページ内検索・タブ検索)
//     → updateNSView で塗り直す (DecoPalette.apply)
//   - 読書モードの CSS
//     → 入場の度に今の配色で組み立てる。開いている読書面は次に開くまで前の色のまま
//

import SwiftUI
import AppKit

// MARK: - 配色一式

// 色は 0xRRGGBB の整数で持つ。
// SwiftUI の Color から 16 進を取り出すのは面倒なので、
// 読書モードの CSS へそのまま流せる形を正にしておく
struct DecoPalette {
    let ink: UInt32        // いちばん奥の地
    let panel: UInt32      // 盤の地
    let panel2: UInt32     // 盤の地 (一段明るい)
    let field: UInt32      // 入力欄の地
    let gold: UInt32       // 主役の金
    let cream: UInt32      // 本文の文字
    // 以下二つは名前に Gold と付いているが、役目は「控えめな文字」と「淡い罫」。
    // 緑青の配色では金ではなく緑青の側に寄せてある
    let dimGold: UInt32
    let faintGold: UInt32
    let rust: UInt32       // 警告の錆色
    // 明るい地の配色か。アイボリーだけが true。
    // 釦・トグル・スクロールバーなど、システムが描く部品の明暗をこれに合わせる
    var isLight: Bool = false

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    static func color(_ hex: UInt32) -> Color {
        Color(red:   Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >>  8) & 0xff) / 255,
              blue:  Double( hex        & 0xff) / 255)
    }

    // CSS 用の "#rrggbb"
    static func css(_ hex: UInt32) -> String {
        String(format: "#%06x", hex)
    }

    // ── 黒と金 ── (元からの配色)
    static let blackGold = DecoPalette(
        ink:       0x0d0d0d,
        panel:     0x141210,
        panel2:    0x1a1712,
        field:     0x161310,
        gold:      0xc9a34e,
        cream:     0xe8d9b0,
        dimGold:   0x8a7a52,
        faintGold: 0x5a4c2a,
        // 信号機の赤をそのまま持ち込むと盤全体の色調が壊れるので、
        // 金の隣に置いても喧嘩しないテラコッタに寄せてある。
        // 使い道は警告表示だけ (乱発すれば意味が消える)
        rust:      0xb56a3c
    )

    // ── 緑青と金 ──
    // 銅や青銅が錆びて吹く青緑 (緑青、英語で verdigris)。
    // アール・デコの建物の銅屋根や青銅の扉に金を合わせた取り合わせ。
    //
    // 地は緑青を深く沈めた暗い青緑。金とクリームは黒と金から据え置き。
    // 控えめな文字と淡い罫は、金を薄めると濁ったオリーブ色になるので、
    // 明るい緑青に置き換えた。
    // 明るさ (盤の地との対比) は黒と金のものと揃えてある:
    //   dimGold 4.4 → 4.6、faintGold 2.2 → 2.2
    // 錆色は青緑の補色寄りなので、そのままでよく目立つ
    static let verdigrisGold = DecoPalette(
        ink:       0x0b1d1b,
        panel:     0x0f2523,
        panel2:    0x142c29,
        field:     0x112421,
        gold:      0xc9a34e,
        cream:     0xe8d9b0,
        dimGold:   0x66928a,
        faintGold: 0x325e56,
        rust:      0xb56a3c
    )

    // ── アイボリーと金 ──
    // 象牙色の地に、深い金と墨色の文字。
    // 象牙と漆と金を合わせたアール・デコの調度品 (ジャン・デュナンの漆芸など) の取り合わせ。
    // Skyscraper で唯一の明るい配色。
    //
    // 明るい地では役目の明暗が入れ替わる:
    //   ink/panel/field … 象牙色 (field だけ紙のように一段白く)
    //   cream (本文の文字) … 墨色
    //   gold … 黒と金の金をそのまま置くと地に溶けるので、焼けた金まで沈めた
    // 白地のページと並ぶと黄ばんで見えるので、地は白寄りの象牙にしてある。
    // 金は茶色に転ばないよう、色相を黄に寄せて鮮やかさを上げた。
    // 盤の地との対比は黒と金のものとおおむね揃えてある:
    //   gold 7.9 → 4.3 (これ以上沈めると金ではなく茶色に見える)
    //   cream 13.3 → 13.5、dimGold 4.4 → 4.8、faintGold 2.2 → 2.2、rust 4.5 → 4.9
    static let ivoryGold = DecoPalette(
        ink:       0xf9f6ec,
        panel:     0xf3eee0,
        panel2:    0xebe4d2,
        field:     0xfdfbf5,
        gold:      0x8f6a0e,
        cream:     0x2a2216,
        dimGold:   0x75674c,
        faintGold: 0xb0a079,
        rust:      0xa3502a,
        isLight:   true
    )
}

// MARK: - 配色の名簿

enum DecoTheme: String, CaseIterable, Identifiable {
    case blackGold
    case verdigrisGold
    case ivoryGold

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .blackGold:     "Black & Gold"
        case .verdigrisGold: "Verdigris & Gold"
        case .ivoryGold:     "Ivory & Gold"
        }
    }

    var palette: DecoPalette {
        switch self {
        case .blackGold:     .blackGold
        case .verdigrisGold: .verdigrisGold
        case .ivoryGold:     .ivoryGold
        }
    }
}

// MARK: - 今の配色

// 選んだ配色を覚えておく係。全ての窓で一つ。
//
// ObservableObject ではなく @Observable なのは、見張る側を
// 選ばないため (冒頭の説明を参照)
@Observable
final class DecoThemeStore {
    static let shared = DecoThemeStore()

    static let storageKey = "skyscraper.theme"

    var theme: DecoTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        // 知らない値 (先の版で足した配色から戻した時など) は黒と金へ
        let saved = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        theme = DecoTheme(rawValue: saved) ?? .blackGold
    }
}

// MARK: - アール・デコ配色

enum Deco {
    private static var palette: DecoPalette { DecoThemeStore.shared.theme.palette }

    static var ink:       Color { DecoPalette.color(palette.ink) }
    static var panel:     Color { DecoPalette.color(palette.panel) }
    static var panel2:    Color { DecoPalette.color(palette.panel2) }
    static var field:     Color { DecoPalette.color(palette.field) }
    static var gold:      Color { DecoPalette.color(palette.gold) }
    static var cream:     Color { DecoPalette.color(palette.cream) }
    static var dimGold:   Color { DecoPalette.color(palette.dimGold) }
    static var faintGold: Color { DecoPalette.color(palette.faintGold) }
    static var rust:      Color { DecoPalette.color(palette.rust) }

    // 窓ごとに .preferredColorScheme(Deco.scheme) で使う。
    // 明るい配色でシステムの部品まで暗いままだと、象牙の地に黒い釦が浮く
    static var scheme: ColorScheme { palette.colorScheme }
}

// MARK: - AppKit の入力欄を塗る

extension NSTextField {
    // 文字色と、薄字 (placeholder) の色を今の配色で塗る。
    // makeNSView と updateNSView の両方から呼ぶ。
    // 色が変わっていなければ何もしない (打鍵の度に呼ばれるので)
    func applyDecoColors(text: Color, placeholder: String, font: NSFont?) {
        let textColor = NSColor(text)
        if self.textColor != textColor {
            self.textColor = textColor
        }
        let placeholderColor = NSColor(Deco.dimGold)
        var current: NSColor?
        if let existing = placeholderAttributedString, existing.length > 0 {
            current = existing.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        if current != placeholderColor || placeholderAttributedString?.string != placeholder {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: placeholderColor]
            if let font { attributes[.font] = font }
            placeholderAttributedString = NSAttributedString(string: placeholder, attributes: attributes)
        }
    }
}
