//
//  LobbyTime.swift
//  Skyscraper
//
//  時間で変わるロビー。新規タブの盤のビルが、時刻に合わせて姿を変える。
//
//  ── 時間帯 ── (時刻で固定。季節では動かさない)
//  朝焼け  5:00〜 6:59  放射の光が金に強まり、早起きの窓がちらほら灯る
//  昼      7:00〜16:59  これまでのロビーと同じ姿。窓は灯らない
//  夕暮れ 17:00〜18:59  放射の光が銅色に染まり、窓が半分ほど灯る
//  夜     19:00〜 4:59  放射の光は沈み、窓はほとんど灯り、星と月が出る。尖塔の先に灯り
//
//  どの窓が灯るかは窓ごとに決め打ちしてある (毎分ちらつかないように)。
//  灯る割合だけが時間帯で変わる。開いているタブの数とは関係ない。
//
//  ── 確かめる時 ──
//  時計を動かさずに見るには、UserDefaults の skyscraper.lobby.phase に
//  dawn / day / dusk / night のどれかを書けば、その時間帯に固定される。
//  消せば時計に戻る
//

import SwiftUI

enum LobbyPhase: String {
    case dawn, day, dusk, night

    static let overrideKey = "skyscraper.lobby.phase"

    static func at(_ date: Date) -> LobbyPhase {
        if let raw = UserDefaults.standard.string(forKey: overrideKey),
           let fixed = LobbyPhase(rawValue: raw) {
            return fixed
        }
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<7:   return .dawn
        case 7..<17:  return .day
        case 17..<19: return .dusk
        default:      return .night
        }
    }

    // 窓の灯る割合
    var litWindows: Double {
        switch self {
        case .dawn:  0.25
        case .day:   0
        case .dusk:  0.5
        case .night: 0.8
        }
    }

    // 放射の光の色。要 (下) から先端 (上) へ闇に溶ける
    var rayColors: [Color] {
        switch self {
        case .dawn:  [Deco.gold.opacity(0.7), Deco.faintGold.opacity(0.05)]
        case .day:   [Deco.faintGold, Deco.faintGold.opacity(0.10)]
        case .dusk:  [Deco.rust, Deco.rust.opacity(0.08)]
        case .night: [Deco.faintGold.opacity(0.35), Deco.faintGold.opacity(0)]
        }
    }
}

// MARK: - 窓

// 一つの段の窓の格子。
// seed は段ごとにずらす番号で、どの窓が灯るかの決め打ちに使う
struct WindowGrid: View {
    let cols: Int
    let rows: Int
    let seed: Int
    let lit: Double

    var body: some View {
        Canvas { context, size in
            let cellW = size.width / CGFloat(cols)
            let cellH = size.height / CGFloat(rows)
            let w = max(cellW * 0.45, 1.5)
            let h = max(cellH * 0.55, 1.5)
            for row in 0..<rows {
                for col in 0..<cols {
                    let rect = CGRect(x: CGFloat(col) * cellW + (cellW - w) / 2,
                                      y: CGFloat(row) * cellH + (cellH - h) / 2,
                                      width: w, height: h)
                    let isLit = Self.glow(seed + row * cols + col) < lit
                    // 消えている窓もうっすら描く。夕方以降、ビルに窓の目地が見えるように
                    let color = isLit ? Deco.gold.opacity(0.9) : Deco.faintGold.opacity(0.18)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }

    // 窓ごとの「灯りやすさ」(0〜1)。番号から決め打ちで出す。
    // 乱数にしないのは、毎分の描き直しで窓がちらつかないため
    private static func glow(_ index: Int) -> Double {
        var x = UInt32(truncatingIfNeeded: index &+ 1) &* 2_654_435_761
        x ^= x >> 15
        x = x &* 2_246_822_519
        x ^= x >> 13
        return Double(x % 1000) / 1000
    }
}

// MARK: - 尖塔の灯り (夜だけ)

struct BeaconLight: View {
    var body: some View {
        Circle()
            .fill(Deco.gold)
            .frame(width: 3, height: 3)
            .shadow(color: Deco.gold.opacity(0.9), radius: 3)
    }
}

// MARK: - 夜空 (星と三日月)

// サンバーストと同じ枠 (330×150) に描く。
// 星の位置は決め打ち。ビルの立つ真ん中の帯は避けてある
struct NightSky: View {
    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (0.06, 0.30, 0.8), (0.13, 0.08, 1.1), (0.19, 0.52, 0.7), (0.25, 0.22, 0.9),
        (0.31, 0.62, 0.6), (0.34, 0.05, 0.8), (0.67, 0.12, 0.9), (0.70, 0.48, 0.6),
        (0.76, 0.30, 0.7), (0.90, 0.40, 1.0), (0.94, 0.10, 0.7), (0.97, 0.60, 0.6),
    ]

    var body: some View {
        Canvas { context, size in
            for star in Self.stars {
                let rect = CGRect(x: star.x * size.width - star.r,
                                  y: star.y * size.height - star.r,
                                  width: star.r * 2, height: star.r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Deco.cream.opacity(0.7)))
            }
            // 三日月。満月を描いて、少しずらした夜の色の円で欠けさせる
            let moon = CGRect(x: size.width * 0.84 - 7, y: size.height * 0.20 - 7,
                              width: 14, height: 14)
            context.fill(Path(ellipseIn: moon), with: .color(Deco.gold.opacity(0.85)))
            context.fill(Path(ellipseIn: moon.offsetBy(dx: 4, dy: -2)),
                         with: .color(Deco.ink))
        }
    }
}
