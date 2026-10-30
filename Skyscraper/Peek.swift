//
//  Peek.swift
//  Skyscraper
//
//  覗き窓。⌥クリックしたリンクを、タブを増やさず今のページの上に浮かべて見る。
//
//  ── 中身は本物のタブ ──
//  覗き窓の中身は TabManager.makeTab で作った Tab そのもので、
//  名簿 (tabs) に載せていないだけだ。だからパスワードの差し込み・
//  広告ブロック・プロファイル・プライベートの置き場は全部そのまま効く。
//  「Open as Tab」は読み込み直さず、この Tab を名簿へ差し込むだけで済む。
//
//  名簿に載っていないので、セッションの保存・タブの見回り (畳む)・
//  AI のグループ分け・拡張の tabs API のどれにも出てこない。
//  タブになった瞬間から、全部に顔を出す。
//
//  ── 閉じ方 ──
//  Esc、外側を押す、× を押す、⌘W。別のタブへ移った時も閉じる。
//  閉じる時は ⇧⌘T の控えに積まない——タブとして開いた物ではないから。
//
//  TabManager の側 (openPeek / closePeek / promotePeek) は、
//  makeTab と後片付けが private なので ContentView.swift に置いてある
//

import AppKit
import SwiftUI
import WebKit

struct PeekOverlay: View {
    @ObservedObject var tab: Tab
    let onClose: () -> Void
    let onPromote: () -> Void

    // Esc を拾う見張り。WKWebView が焦点を持っていても届くよう、
    // SwiftUI の onExitCommand ではなく AppKit の層で拾う
    @State private var escMonitor: Any?

    var body: some View {
        ZStack {
            // 外側の帳。押せば閉じる
            Deco.ink.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                header
                Rectangle().fill(Deco.faintGold).frame(height: 1)
                WebView(webView: tab.webView, isInteractive: true)
                    .id(tab.webViewGeneration)
            }
            .background(Deco.ink)
            // 金の二重罫。外は濃く、内は淡く
            .overlay(Rectangle().stroke(Deco.gold, lineWidth: 1))
            .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1).padding(-5))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .padding(.horizontal, 56)
            .padding(.vertical, 32)
        }
        .onAppear(perform: startEscWatch)
        .onDisappear(perform: stopEscWatch)
    }

    // ── 見出し ──

    private var header: some View {
        HStack(spacing: 10) {
            // 菱形の点。縦タブの見出しと同じ意匠
            Image(systemName: "diamond.fill")
                .font(.system(size: 6))
                .foregroundColor(Deco.gold)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.cream)
                    .lineLimit(1)
                Text(host)
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if tab.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Deco.gold)
            }

            Button(action: onPromote) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.square")
                    Text("Open as Tab")
                }
                .font(.system(size: 11, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Open as Tab (⌘↩)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Deco.gold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Deco.panel)
    }

    private var title: String {
        tab.pageTitle.isEmpty ? host : tab.pageTitle
    }

    private var host: String {
        tab.webView.url?.host() ?? URL(string: tab.urlText)?.host() ?? tab.urlText
    }

    // ── Esc ──
    //
    // 窓が二枚あってそれぞれ覗き窓を開いていても、押された窓の分だけ閉じる。
    // 全画面再生中は WebView が別の窓へ出ているので、この照合で自然に外れる
    // (全画面を抜ける Esc で覗き窓まで閉じない)
    private func startEscWatch() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  let window = tab.webView.window,
                  event.window === window else { return event }
            onClose()
            return nil
        }
    }

    private func stopEscWatch() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }
}
