//
//  ElevatorDial.swift
//  Skyscraper
//
//  エレベーターの針。読み込みの進み具合を、アール・デコのビルの
//  エレベーターの扉の上にある、半円の文字盤と針で見せる。
//
//  針は estimatedProgress (0〜1) を指す。左端が一階、右端が最上階。
//  読み終わると右端まで振り切り、少し置いてから消える。
//  消す・出すの段取りは置き場の側 (BrowserPane) が持ち、
//  ここは「今どこを指すか」だけを受け持つ
//

import SwiftUI

struct ElevatorDial: View {
    let isLoading: Bool
    let progress: Double

    // 今指している位置。進み具合をそのまま描かず、ここを経由して動かす——
    // 値が飛んでも針がなめらかに振れるように
    @State private var needle: Double = 0

    var body: some View {
        ZStack {
            DialFace()
                .stroke(Deco.faintGold, lineWidth: 1)
            DialTicks()
                .stroke(Deco.dimGold, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            DialNeedle(value: needle)
                .stroke(Deco.gold, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            DialHub()
                .fill(Deco.gold)
        }
        .frame(width: 26, height: 15)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
        // 進み具合の読み上げ。% の付け方は言語で違うので、書式の道具に任せる
        // (文字で "\(数)%" と組むと、String Catalog が訳し分けられないと警告する)
        .accessibilityValue(Text(needle, format: .percent.precision(.fractionLength(0))))
        .onAppear {
            needle = isLoading ? max(progress, 0.04) : 1
        }
        .onChange(of: progress) { _, value in
            guard isLoading else { return }
            withAnimation(.easeOut(duration: 0.25)) { needle = max(value, 0.04) }
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                // 次の読み込みが始まった。針を一階へ戻す
                withAnimation(.easeInOut(duration: 0.2)) { needle = max(progress, 0.04) }
            } else {
                // 着いた。最上階まで振り切る
                withAnimation(.easeOut(duration: 0.3)) { needle = 1 }
            }
        }
    }
}

// MARK: - 文字盤の部品
//
// セオドアの紋章 (Directory.swift の TheodoreEmblem) も借りるので private にしない。
// どれも同じ枠 (幅いっぱいの半円、要は下辺の中央) で描く。
// 要の位置と半径はここで一度だけ決める

private struct DialGeometry {
    let center: CGPoint
    let radius: CGFloat

    init(_ rect: CGRect) {
        radius = min(rect.width / 2, rect.height) - 1.5
        center = CGPoint(x: rect.midX, y: rect.maxY - 1.5)
    }

    // θ は左端 (π) から右端 (0) へ。画面は y が下向きなので sin を引く
    func point(_ theta: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + r * CGFloat(cos(theta)),
                y: center.y - r * CGFloat(sin(theta)))
    }

    // 進み具合 (0〜1) を角度へ
    static func angle(for value: Double) -> Double {
        .pi * (1 - min(max(value, 0), 1))
    }
}

// 外周の弧と、足元の水平の罫
struct DialFace: Shape {
    func path(in rect: CGRect) -> Path {
        let g = DialGeometry(rect)
        var path = Path()
        let segments = 32
        for i in 0...segments {
            let p = g.point(.pi * (1 - Double(i) / Double(segments)), g.radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.move(to: CGPoint(x: g.center.x - g.radius, y: g.center.y))
        path.addLine(to: CGPoint(x: g.center.x + g.radius, y: g.center.y))
        return path
    }
}

// 階の目盛り。九本で、一つおきに長い
struct DialTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let g = DialGeometry(rect)
        var path = Path()
        for i in 0...8 {
            let theta = .pi * (1 - Double(i) / 8)
            let inner = g.radius * (i.isMultiple(of: 2) ? 0.62 : 0.76)
            path.move(to: g.point(theta, inner))
            path.addLine(to: g.point(theta, g.radius * 0.9))
        }
        return path
    }
}

// 針。value を animatableData にしてあるので、間の角度も描かれる
struct DialNeedle: Shape {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let g = DialGeometry(rect)
        var path = Path()
        path.move(to: g.center)
        path.addLine(to: g.point(DialGeometry.angle(for: value), g.radius * 0.84))
        return path
    }
}

// 針の要
struct DialHub: Shape {
    func path(in rect: CGRect) -> Path {
        let g = DialGeometry(rect)
        return Path(ellipseIn: CGRect(x: g.center.x - 1.8, y: g.center.y - 1.8,
                                      width: 3.6, height: 3.6))
    }
}
