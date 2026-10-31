//
//  ModelLanguage.swift
//  Skyscraper
//
//  オンデバイスモデル (Foundation Models) に渡す文の掃除と言語判定。
//  タブのグループ分け (TabGrouper.swift) とセオドア (Theodore.swift) が共に使う。
//
//  Foundation Models はプロンプトに非対応言語が混ざると丸ごと拒否する。
//  @ハンドルなどのローマ字ノイズが外国語と誤判定されがちなので、
//  「判定する文」と「モデルに送る文」を必ず同じ掃除 (sanitize) を通した文にする。
//  ここが食い違うと、こちらの判定で通した行が Apple 側で弾かれ続ける。
//

import Foundation
import NaturalLanguage
import FoundationModels

@MainActor
enum ModelLanguage {
    // @ハンドル・URLなど、言語判定を狂わせるノイズを取り除く。
    // 言語判定 (isSupported) とモデルへの送信文の両方で
    // 必ずこれを通し、判定対象と実際に送る文を一致させる
    static func sanitize(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: "@[A-Za-z0-9_]+", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "https?://\\S+", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 言語判定に渡す下駄 (事前確率)。モデルの対応言語を重めにする。
    // "Home - Instapaper" のような短い英語の題がカタルーニャ語 (ca 0.64) と
    // 読み違えられ、毎回外されていた (2026-09 実測)。迷う程度の短い題は
    // 対応言語側に倒し、文字種から明らかな外国語は下駄では覆らない想定。
    // 中国語だけは NLLanguage が簡体・繁体に分かれるので両方に付ける
    private static let hints: [NLLanguage: Double] = {
        var hints: [NLLanguage: Double] = [:]
        for language in SystemLanguageModel.default.supportedLanguages {
            guard let code = language.languageCode?.identifier else { continue }
            if code == "zh" {
                hints[.simplifiedChinese] = 1.0
                hints[.traditionalChinese] = 1.0
            } else {
                hints[NLLanguage(rawValue: code)] = 1.0
            }
        }
        return hints
    }()

    private static let supportedCodes: Set<String> = Set(
        SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier }
    )

    // 文の言語がモデルの対応言語かどうか (sanitize 済みの文で判定)。
    // strict = false：確信度が高く非対応と分かったときだけ弾く(通常運転)
    // strict = true ：非対応が最有力なら弾く (拒否された実績があるとき)
    static func isSupported(_ text: String, strict: Bool) -> Bool {
        let cleaned = sanitize(text)
        guard !cleaned.isEmpty else { return true }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = hints
        recognizer.processString(cleaned)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else {
            return true
        }
        // 短い題の言語判定は揺れるので、緩い判定では
        // 確信度 0.6 超のときだけ除外の対象にする
        if !strict && confidence <= 0.6 { return true }

        let code = Locale.Language(identifier: language.rawValue).languageCode?.identifier
            ?? language.rawValue
        return supportedCodes.contains(code)
    }
}
