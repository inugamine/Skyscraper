//
//  Acknowledgements.swift
//  Skyscraper
//
//  同梱している第三者ソフトウェアの権利表示。
//
//  Sparkle は MIT、Readability.js は Apache-2.0。どちらも
//  「配布物に著作権表示を含めること」を条件にしている。
//  README や NOTICE に書いただけでは、.app だけを受け取った人には届かない。
//  だから設定画面から読める場所にも置く。
//
//  ライセンス本文は翻訳しない。原文のままでなければ意味がないので、
//  Localizable.xcstrings には載せず Swift の文字列として直接持つ。
//

import SwiftUI
import Foundation

// ── 一件分 ──
struct Acknowledgement: Identifiable {
    let id: String              // name をそのまま鍵にする
    let name: String
    let role: LocalizedStringKey
    let licenseName: String
    let urlString: String
    let licenseText: String

    var url: URL? { URL(string: urlString) }
}

enum Acknowledgements {

    static let all: [Acknowledgement] = [sparkle, readability]

    // ══ Sparkle ══
    static let sparkle = Acknowledgement(
        id: "Sparkle",
        name: "Sparkle",
        role: "Software update framework",
        licenseName: "MIT License",
        urlString: "https://sparkle-project.org/",
        licenseText: """
        Copyright (c) 2006-2013 Andy Matuschak.
        Copyright (c) 2009-2013 Elgato Systems GmbH.
        Copyright (c) 2011-2014 Kornel Lesiński.
        Copyright (c) 2015-2017 Mayur Pawashe.
        Copyright (c) 2014 C.W. Betts.
        Copyright (c) 2014 Petroules Corporation.
        Copyright (c) 2014 Big Nerd Ranch.
        All rights reserved.

        Permission is hereby granted, free of charge, to any person obtaining a copy of
        this software and associated documentation files (the "Software"), to deal in
        the Software without restriction, including without limitation the rights to
        use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
        the Software, and to permit persons to whom the Software is furnished to do so,
        subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
        FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
        COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
        IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
        CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

        =================
        EXTERNAL LICENSES
        =================

        bspatch.c and bsdiff.c, from bsdiff 4.3
        <http://www.daemonology.net/bsdiff/>:

        Copyright 2003-2005 Colin Percival
        All rights reserved

        Redistribution and use in source and binary forms, with or without
        modification, are permitted providing that the following conditions
        are met:
        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice, this list of conditions and the following disclaimer in the
           documentation and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
        ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
        OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
        IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
        POSSIBILITY OF SUCH DAMAGE.

        --

        sais.c and sais.h, from sais-lite (2010/08/07)
        <https://sites.google.com/site/yuta256/sais>:

        Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

        Permission is hereby granted, free of charge, to any person
        obtaining a copy of this software and associated documentation
        files (the "Software"), to deal in the Software without
        restriction, including without limitation the rights to use,
        copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the
        Software is furnished to do so, subject to the following
        conditions:

        The above copyright notice and this permission notice shall be
        included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
        EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
        OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
        HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
        WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
        FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
        OTHER DEALINGS IN THE SOFTWARE.

        --

        Portable C implementation of Ed25519,
        from https://github.com/orlp/ed25519

        Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

        This software is provided 'as-is', without any express or implied warranty.
        In no event will the authors be held liable for any damages arising from the
        use of this software.

        Permission is granted to anyone to use this software for any purpose,
        including commercial applications, and to alter it and redistribute it
        freely, subject to the following restrictions:

        1. The origin of this software must not be misrepresented; you must not
           claim that you wrote the original software. If you use this software in a
           product, an acknowledgment in the product documentation would be
           appreciated but is not required.

        2. Altered source versions must be plainly marked as such, and must not be
           misrepresented as being the original software.

        3. This notice may not be removed or altered from any source distribution.

        --

        SUSignatureVerifier.m:

        Copyright (c) 2011 Mark Hamlin.
        All rights reserved.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted providing that the following conditions
        are met:
        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice, this list of conditions and the following disclaimer in the
           documentation and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
        ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
        OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
        IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
        POSSIBILITY OF SUCH DAMAGE.
        """
    )

    // ══ Readability.js ══
    static let readability = Acknowledgement(
        id: "Readability.js",
        name: "Readability.js",
        role: "Article extraction for Reader mode",
        licenseName: "Apache License 2.0",
        urlString: "https://github.com/mozilla/readability",
        licenseText: """
        Copyright (c) 2010 Arc90 Inc
        Maintained by the Mozilla Foundation and contributors.

        Licensed under the Apache License, Version 2.0 (the "License");
        you may not use this file except in compliance with the License.
        You may obtain a copy of the License at

            http://www.apache.org/licenses/LICENSE-2.0

        Unless required by applicable law or agreed to in writing, software
        distributed under the License is distributed on an "AS IS" BASIS,
        WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
        See the License for the specific language governing permissions and
        limitations under the License.

        Skyscraper bundles this file unmodified.
        """
    )

    // ══ Apache License 2.0 の全文 ══
    //
    // Skyscraper 本体と Readability.js の両方がこのライセンスだ。
    // 第 4 条(a) は「受け取った人にライセンスの写しを渡せ」と言っている。
    // .app だけを受け取った人にはリポジトリの LICENSE が届かないので、
    // URL を示すだけでは足りない。ここに全文を持つ。
    //
    // 末尾の APPENDIX にある Copyright [yyyy] [name of copyright owner] は
    // ソースの頭に貼る雛形であって、埋める欄ではない。角括弧のままが正しい。
    static let apacheLicense = Acknowledgement(
        id: "Apache-2.0",
        name: "Apache License 2.0",
        role: "Applies to Skyscraper itself and to Readability.js",
        licenseName: "January 2004",
        urlString: "https://www.apache.org/licenses/LICENSE-2.0",
        licenseText: apacheLicenseText
    )

    private static let apacheLicenseText = """
                                         Apache License
                                   Version 2.0, January 2004
                                http://www.apache.org/licenses/

           TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

           1. Definitions.

              "License" shall mean the terms and conditions for use, reproduction,
              and distribution as defined by Sections 1 through 9 of this document.

              "Licensor" shall mean the copyright owner or entity authorized by
              the copyright owner that is granting the License.

              "Legal Entity" shall mean the union of the acting entity and all
              other entities that control, are controlled by, or are under common
              control with that entity. For the purposes of this definition,
              "control" means (i) the power, direct or indirect, to cause the
              direction or management of such entity, whether by contract or
              otherwise, or (ii) ownership of fifty percent (50%) or more of the
              outstanding shares, or (iii) beneficial ownership of such entity.

              "You" (or "Your") shall mean an individual or Legal Entity
              exercising permissions granted by this License.

              "Source" form shall mean the preferred form for making modifications,
              including but not limited to software source code, documentation
              source, and configuration files.

              "Object" form shall mean any form resulting from mechanical
              transformation or translation of a Source form, including but
              not limited to compiled object code, generated documentation,
              and conversions to other media types.

              "Work" shall mean the work of authorship, whether in Source or
              Object form, made available under the License, as indicated by a
              copyright notice that is included in or attached to the work
              (an example is provided in the Appendix below).

              "Derivative Works" shall mean any work, whether in Source or Object
              form, that is based on (or derived from) the Work and for which the
              editorial revisions, annotations, elaborations, or other modifications
              represent, as a whole, an original work of authorship. For the purposes
              of this License, Derivative Works shall not include works that remain
              separable from, or merely link (or bind by name) to the interfaces of,
              the Work and Derivative Works thereof.

              "Contribution" shall mean any work of authorship, including
              the original version of the Work and any modifications or additions
              to that Work or Derivative Works thereof, that is intentionally
              submitted to Licensor for inclusion in the Work by the copyright owner
              or by an individual or Legal Entity authorized to submit on behalf of
              the copyright owner. For the purposes of this definition, "submitted"
              means any form of electronic, verbal, or written communication sent
              to the Licensor or its representatives, including but not limited to
              communication on electronic mailing lists, source code control systems,
              and issue tracking systems that are managed by, or on behalf of, the
              Licensor for the purpose of discussing and improving the Work, but
              excluding communication that is conspicuously marked or otherwise
              designated in writing by the copyright owner as "Not a Contribution."

              "Contributor" shall mean Licensor and any individual or Legal Entity
              on behalf of whom a Contribution has been received by Licensor and
              subsequently incorporated within the Work.

           2. Grant of Copyright License. Subject to the terms and conditions of
              this License, each Contributor hereby grants to You a perpetual,
              worldwide, non-exclusive, no-charge, royalty-free, irrevocable
              copyright license to reproduce, prepare Derivative Works of,
              publicly display, publicly perform, sublicense, and distribute the
              Work and such Derivative Works in Source or Object form.

           3. Grant of Patent License. Subject to the terms and conditions of
              this License, each Contributor hereby grants to You a perpetual,
              worldwide, non-exclusive, no-charge, royalty-free, irrevocable
              (except as stated in this section) patent license to make, have made,
              use, offer to sell, sell, import, and otherwise transfer the Work,
              where such license applies only to those patent claims licensable
              by such Contributor that are necessarily infringed by their
              Contribution(s) alone or by combination of their Contribution(s)
              with the Work to which such Contribution(s) was submitted. If You
              institute patent litigation against any entity (including a
              cross-claim or counterclaim in a lawsuit) alleging that the Work
              or a Contribution incorporated within the Work constitutes direct
              or contributory patent infringement, then any patent licenses
              granted to You under this License for that Work shall terminate
              as of the date such litigation is filed.

           4. Redistribution. You may reproduce and distribute copies of the
              Work or Derivative Works thereof in any medium, with or without
              modifications, and in Source or Object form, provided that You
              meet the following conditions:

              (a) You must give any other recipients of the Work or
                  Derivative Works a copy of this License; and

              (b) You must cause any modified files to carry prominent notices
                  stating that You changed the files; and

              (c) You must retain, in the Source form of any Derivative Works
                  that You distribute, all copyright, patent, trademark, and
                  attribution notices from the Source form of the Work,
                  excluding those notices that do not pertain to any part of
                  the Derivative Works; and

              (d) If the Work includes a "NOTICE" text file as part of its
                  distribution, then any Derivative Works that You distribute must
                  include a readable copy of the attribution notices contained
                  within such NOTICE file, excluding those notices that do not
                  pertain to any part of the Derivative Works, in at least one
                  of the following places: within a NOTICE text file distributed
                  as part of the Derivative Works; within the Source form or
                  documentation, if provided along with the Derivative Works; or,
                  within a display generated by the Derivative Works, if and
                  wherever such third-party notices normally appear. The contents
                  of the NOTICE file are for informational purposes only and
                  do not modify the License. You may add Your own attribution
                  notices within Derivative Works that You distribute, alongside
                  or as an addendum to the NOTICE text from the Work, provided
                  that such additional attribution notices cannot be construed
                  as modifying the License.

              You may add Your own copyright statement to Your modifications and
              may provide additional or different license terms and conditions
              for use, reproduction, or distribution of Your modifications, or
              for any such Derivative Works as a whole, provided Your use,
              reproduction, and distribution of the Work otherwise complies with
              the conditions stated in this License.

           5. Submission of Contributions. Unless You explicitly state otherwise,
              any Contribution intentionally submitted for inclusion in the Work
              by You to the Licensor shall be under the terms and conditions of
              this License, without any additional terms or conditions.
              Notwithstanding the above, nothing herein shall supersede or modify
              the terms of any separate license agreement you may have executed
              with Licensor regarding such Contributions.

           6. Trademarks. This License does not grant permission to use the trade
              names, trademarks, service marks, or product names of the Licensor,
              except as required for reasonable and customary use in describing the
              origin of the Work and reproducing the content of the NOTICE file.

           7. Disclaimer of Warranty. Unless required by applicable law or
              agreed to in writing, Licensor provides the Work (and each
              Contributor provides its Contributions) on an "AS IS" BASIS,
              WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
              implied, including, without limitation, any warranties or conditions
              of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
              PARTICULAR PURPOSE. You are solely responsible for determining the
              appropriateness of using or redistributing the Work and assume any
              risks associated with Your exercise of permissions under this License.

           8. Limitation of Liability. In no event and under no legal theory,
              whether in tort (including negligence), contract, or otherwise,
              unless required by applicable law (such as deliberate and grossly
              negligent acts) or agreed to in writing, shall any Contributor be
              liable to You for damages, including any direct, indirect, special,
              incidental, or consequential damages of any character arising as a
              result of this License or out of the use or inability to use the
              Work (including but not limited to damages for loss of goodwill,
              work stoppage, computer failure or malfunction, or any and all
              other commercial damages or losses), even if such Contributor
              has been advised of the possibility of such damages.

           9. Accepting Warranty or Additional Liability. While redistributing
              the Work or Derivative Works thereof, You may choose to offer,
              and charge a fee for, acceptance of support, warranty, indemnity,
              or other liability obligations and/or rights consistent with this
              License. However, in accepting such obligations, You may act only
              on Your own behalf and on Your sole responsibility, not on behalf
              of any other Contributor, and only if You agree to indemnify,
              defend, and hold each Contributor harmless for any liability
              incurred by, or claims asserted against, such Contributor by reason
              of your accepting any such warranty or additional liability.

           END OF TERMS AND CONDITIONS

           APPENDIX: How to apply the Apache License to your work.

              To apply the Apache License to your work, attach the following
              boilerplate notice, with the fields enclosed by brackets "[]"
              replaced with your own identifying information. (Don't include
              the brackets!)  The text should be enclosed in the appropriate
              comment syntax for the file format. We also recommend that a
              file or class name and description of purpose be included on the
              same "printed page" as the copyright notice for easier
              identification within third-party archives.

           Copyright [yyyy] [name of copyright owner]

           Licensed under the Apache License, Version 2.0 (the "License");
           you may not use this file except in compliance with the License.
           You may obtain a copy of the License at

               http://www.apache.org/licenses/LICENSE-2.0

           Unless required by applicable law or agreed to in writing, software
           distributed under the License is distributed on an "AS IS" BASIS,
           WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
           See the License for the specific language governing permissions and
           limitations under the License.
    """
}

// ══════════════════════════════════════════════════════════
//  画面
// ══════════════════════════════════════════════════════════

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // 開いている項目。既定はすべて畳んでおく
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── 見出し ──
            HStack(spacing: 8) {
                Image(systemName: "diamond")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.gold)
                Text("Acknowledgements")
                    .font(.system(size: 14, design: .serif))
                    .tracking(3)
                    .foregroundColor(Deco.cream)
                Spacer()
            }
            .padding(.bottom, 10)

            Zigzag(teeth: 22)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.bottom, 14)

            Text("Skyscraper is built on the work of others. The licenses below are reproduced in full.")
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.dimGold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            // ── 一覧 ──
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Acknowledgements.all) { item in
                        entry(item)
                    }

                    // ── ライセンス本文 ──
                    Zigzag(teeth: 22)
                        .stroke(Deco.faintGold, lineWidth: 1)
                        .frame(height: 5)
                        .padding(.vertical, 6)

                    entry(Acknowledgements.apacheLicense)
                }
                .padding(.trailing, 4)
            }

            // ── 閉じる ──
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Close")
                        .font(.system(size: 11, design: .serif))
                        .tracking(1)
                        .foregroundColor(Deco.gold)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 560, height: 620)
        .background(Deco.ink)
        .preferredColorScheme(.dark)
    }

    // ── 一件分の表示 ──
    @ViewBuilder
    private func entry(_ item: Acknowledgement) -> some View {
        let isOpen = expanded.contains(item.id)

        VStack(alignment: .leading, spacing: 8) {

            // 名前と開閉
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(item.id) } else { expanded.insert(item.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Deco.gold)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 12, design: .serif))
                            .tracking(1)
                            .foregroundColor(Deco.cream)
                        Text(item.role)
                            .font(.system(size: 10, design: .serif))
                            .foregroundColor(Deco.dimGold)
                    }

                    Spacer()

                    Text(item.licenseName)
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Deco.gold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 配布元
            if let url = item.url {
                Button {
                    openURL(url)
                } label: {
                    Text(item.urlString)
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Deco.gold)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.leading, 17)
            }

            // ライセンス本文
            if isOpen {
                Text(item.licenseText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Deco.dimGold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1))
                    .padding(.leading, 17)
            }
        }
    }
}

#Preview {
    AcknowledgementsView()
}
