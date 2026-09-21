//
//  PasswordGenerator.swift
//  Skyscraper
//
//  新規登録や変更の画面で渡す、強いパスワードを作る。
//
//  形は Safari と同じ abcdef-ghijk2-lmnOpq 型：
//  6 文字の塊を三つ、ハイフンで繋いだ 20 文字。
//  中身は小文字が主で、大文字と数字を一つずつ混ぜる。
//
//  記号をハイフンだけにしてあるのは、記号を嫌うサイトでも通すため。
//  「大文字・数字・記号をそれぞれ一つ以上」という条件の大半は、
//  これで満たせる。弾かれて作り直す手間の方が、記号を増やして
//  得る強さより高くつく。
//
//  見間違えやすい字 (l と 1、O と 0、I) は最初から外してある。
//  書き写す場面は少ないが、外しても強さはほとんど減らない。
//
//  乱数は SystemRandomNumberGenerator から取る。Apple の環境では
//  暗号用の乱数源 (SecRandomCopyBytes と同じもの) に繋がっている。
//  Int.random(in:using:) は範囲に合わせて偏りなく引くので、
//  バイトを剰余で丸める時の偏りも気にしなくて済む。
//
//  強さの目安：小文字 24 種を 16 箇所、大文字 24 種と数字 8 種を
//  一つずつ、それぞれの位置の選び方も含めて 89 ビットほど。
//

import Foundation

enum PasswordGenerator {

    private static let lower = Array("abcdefghijkmnpqrstuvwxyz")   // l と o を除く
    private static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")   // I と O を除く
    private static let digits = Array("23456789")                  // 0 と 1 を除く

    private static let groupCount = 3
    private static let groupLength = 6

    static func make() -> String {
        var rng = SystemRandomNumberGenerator()
        let length = groupCount * groupLength

        var characters = (0..<length).map { _ in lower.randomElement(using: &rng)! }

        // 大文字と数字を、別々の位置に一つずつ置く
        let upperAt = Int.random(in: 0..<length, using: &rng)
        var digitAt = Int.random(in: 0..<(length - 1), using: &rng)
        if digitAt >= upperAt { digitAt += 1 }

        characters[upperAt] = upper.randomElement(using: &rng)!
        characters[digitAt] = digits.randomElement(using: &rng)!

        // 6 文字ごとに区切る
        return stride(from: 0, to: length, by: groupLength)
            .map { String(characters[$0..<($0 + groupLength)]) }
            .joined(separator: "-")
    }
}
