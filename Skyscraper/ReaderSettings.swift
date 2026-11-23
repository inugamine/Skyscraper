//
//  ReaderSettings.swift
//  Skyscraper
//
//  リーダーの文字の設定 (大きさ・行間・書体・行の長さ) と、しおり。
//  どちらも Mezzanine から持ってきた物 (Mezzanine の ReaderSettings.swift / ReadingMarks.swift / TypographyPanel.swift)。
//
//  文字の設定は紙面 (オーバーレイ) に CSS 変数 (--sr-scale / --sr-leading / --sr-font / --sr-measure) で渡す。
//  変えたら読み込み直さずに変数だけ差し替え、読んでいた位置 (全体のうちの割合) に戻す。
//
//  しおりは作品 (ページの URL) ごとに「どこまで読んだか」を全体のうちの割合 (0〜1) で覚える。
//  ピクセルで覚えると、文字の大きさや行の長さを変えたときにずれるため。
//  プライベートウィンドウでは書かない (読むのは通常の窓の分も読む。許可の記憶と同じ扱い)。
//

import SwiftUI
import Combine

// MARK: - 文字の設定

/// 行間
enum ReaderLeading: String, CaseIterable, Identifiable {
    case tight, standard, loose

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .tight: "Tight"
        case .standard: "Standard"
        case .loose: "Loose"
        }
    }

    var value: Double {
        switch self {
        case .tight: 1.6
        case .standard: 1.9
        case .loose: 2.2
        }
    }
}

/// 書体
enum ReaderTypeface: String, CaseIterable, Identifiable {
    case serif, sans

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans Serif"
        }
    }

    /// CSS の font-family。明朝はこれまでのリーダーと同じ並び
    var css: String {
        switch self {
        case .serif: "Georgia, 'Times New Roman', 'Hiragino Mincho ProN', 'Yu Mincho', serif"
        case .sans: "'Avenir Next', 'Hiragino Sans', sans-serif"
        }
    }
}

/// 行の長さ (本文の列の幅)。em なので、文字を大きくしても一行の字数は変わらない。
/// 標準の 40em は、これまでの 680px (17px × 40) と同じ
enum ReaderMeasure: String, CaseIterable, Identifiable {
    case short, standard, long

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .short: "Short"
        case .standard: "Standard"
        case .long: "Long"
        }
    }

    var css: String {
        switch self {
        case .short: "34em"
        case .standard: "40em"
        case .long: "46em"
        }
    }
}

struct ReaderSettings: Equatable {
    /// 文字の大きさの段階 (1.0 が標準)
    static let scales: [Double] = [0.85, 0.92, 1.0, 1.1, 1.22, 1.36]
    static let defaultSizeStep = 2

    var sizeStep: Int = ReaderSettings.defaultSizeStep
    var leading: ReaderLeading = .standard
    var typeface: ReaderTypeface = .serif
    var measure: ReaderMeasure = .standard

    var scale: Double {
        Self.scales[min(max(sizeStep, 0), Self.scales.count - 1)]
    }

    /// 紙面に渡す CSS 変数。callAsyncJavaScript の引数としてそのまま渡す
    var cssVariables: [String: String] {
        [
            "--sr-scale": String(scale),
            "--sr-leading": String(leading.value),
            "--sr-font": typeface.css,
            "--sr-measure": measure.css,
        ]
    }
}

/// 文字の設定の置き場。全部の窓・タブで一つ。変わったら、リーダー表示中のタブが紙面を差し替える
@MainActor
final class ReaderSettingsStore: ObservableObject {
    static let shared = ReaderSettingsStore()

    private enum Key {
        static let size = "skyscraper.reader.size"
        static let leading = "skyscraper.reader.leading"
        static let typeface = "skyscraper.reader.typeface"
        static let measure = "skyscraper.reader.measure"
    }

    @Published var settings: ReaderSettings {
        didSet { save() }
    }

    private init() {
        let d = UserDefaults.standard
        var s = ReaderSettings()
        if d.object(forKey: Key.size) != nil { s.sizeStep = d.integer(forKey: Key.size) }
        if let v = d.string(forKey: Key.leading).flatMap(ReaderLeading.init) { s.leading = v }
        if let v = d.string(forKey: Key.typeface).flatMap(ReaderTypeface.init) { s.typeface = v }
        if let v = d.string(forKey: Key.measure).flatMap(ReaderMeasure.init) { s.measure = v }
        settings = s
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(settings.sizeStep, forKey: Key.size)
        d.set(settings.leading.rawValue, forKey: Key.leading)
        d.set(settings.typeface.rawValue, forKey: Key.typeface)
        d.set(settings.measure.rawValue, forKey: Key.measure)
    }
}

// MARK: - しおり

struct ReadingMark: Codable, Equatable {
    /// どこまで読んだか (0 = 頭、1 = 終わり)
    var progress: Double
    var title: String
    var updatedAt: Date
    /// 一度でも終わりまで読んだか (読み終わりの扇を最初から金にする)
    var finished: Bool
}

enum ReadingMarks {
    private static let storageKey = "skyscraper.reader.marks.v1"
    /// 覚えておく作品の数。これを超えたら、しばらく開いていない物から忘れる
    private static let limit = 300
    /// ここまで来たら「読み終わった」とみなす (紙面の JS の扇の判定も同じ値)
    static let finishedThreshold = 0.98

    /// 前回の位置から開くか。読み終わった物と、ほとんど頭の物は頭から
    static func resumePosition(for mark: ReadingMark?) -> Double {
        guard let mark, mark.progress > 0.02, mark.progress < finishedThreshold else { return 0 }
        return mark.progress
    }

    static func mark(forKey key: String?) -> ReadingMark? {
        guard let key else { return nil }
        return loadAll()[key]
    }

    static func save(progress: Double, title: String, forKey key: String?) {
        guard let key else { return }
        var all = loadAll()
        let finished = progress >= finishedThreshold || (all[key]?.finished ?? false)
        all[key] = ReadingMark(progress: progress, title: title, updatedAt: .now, finished: finished)

        if all.count > limit {
            let recent = all.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
            all = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func loadAll() -> [String: ReadingMark] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let all = try? JSONDecoder().decode([String: ReadingMark].self, from: data)
        else { return [:] }
        return all
    }
}

// MARK: - 文字の設定の盤 (Aa)

/// アドレスバーの「Aa」。リーダー表示中だけ出る
struct ReaderTypographyButton: View {
    @ObservedObject var tab: Tab
    @State private var showing = false

    var body: some View {
        if tab.isReaderActive {
            Button {
                showing.toggle()
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 13))
                    .foregroundColor(showing ? Deco.cream : Deco.gold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Text Settings")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ReaderTypographyPanel()
            }
        }
    }
}

/// 動かすとその場で紙面に反映される (読んでいる位置はそのまま)
private struct ReaderTypographyPanel: View {
    @ObservedObject private var store = ReaderSettingsStore.shared

    private var stepCount: Int { ReaderSettings.scales.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Text Size") {
                HStack {
                    stepButton(systemImage: "textformat.size.smaller", label: "Smaller",
                               disabled: store.settings.sizeStep <= 0) { store.settings.sizeStep -= 1 }
                    Spacer()
                    // 今の段階を菱形の点で見せる
                    HStack(spacing: 8) {
                        ForEach(0..<stepCount, id: \.self) { i in
                            Rectangle()
                                .fill(i <= store.settings.sizeStep ? Deco.gold : Deco.faintGold.opacity(0.5))
                                .frame(width: 6, height: 6)
                                .rotationEffect(.degrees(45))
                        }
                    }
                    Spacer()
                    stepButton(systemImage: "textformat.size.larger", label: "Larger",
                               disabled: store.settings.sizeStep >= stepCount - 1) { store.settings.sizeStep += 1 }
                }
            }

            section("Line Spacing") {
                Picker("Line Spacing", selection: $store.settings.leading) {
                    ForEach(ReaderLeading.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            section("Typeface") {
                Picker("Typeface", selection: $store.settings.typeface) {
                    ForEach(ReaderTypeface.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            section("Line Length") {
                Picker("Line Length", selection: $store.settings.measure) {
                    ForEach(ReaderMeasure.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 280, alignment: .leading)
        .background(Deco.panel)
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, design: .serif))
                .tracking(2)
                .foregroundStyle(Deco.dimGold)
            content()
        }
    }

    private func stepButton(systemImage: String, label: LocalizedStringKey, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(disabled ? Deco.faintGold : Deco.gold)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}
