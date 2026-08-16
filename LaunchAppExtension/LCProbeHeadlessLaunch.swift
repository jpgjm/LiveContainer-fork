//
//  LCProbeHeadlessLaunch.swift
//  LaunchAppExtension
//
//  【フォーク独自の追加ファイル。本家には存在しない】
//
//  目的:
//    「ゲストアプリを画面を出さずに起動できるか」を実機で確かめるための
//    調査用 App Intent。結果をテキストに書き出すだけで、それ以外は何もしない。
//
//  背景:
//    ゲストアプリが宣言した App Intents は installd に登録されないため、
//    AlarmKit の停止 / スヌーズボタンから解決できない (実測済み)。
//    一方 LiveContainer 自身が宣言した Intent は解決される
//    (ショートカットの "Launch App" が動くことで確認済み)。
//
//    ただし "Launch App" は openURL でホストを前面に出すため、画面が点く。
//    画面を出さずにゲストを動かすには、SideStore の Refresh All Apps と
//    同じ経路 —— NSExtension で LiveProcess.appex を別プロセス起動する ——
//    を通す必要がある。
//
//    App Extension はホストがシーンを渡さない限り UI を持たないので、
//    この経路なら自動的にヘッドレスになる。
//
//  このプローブで確かめること:
//    1. この Intent がどのプロセスで走るか (pid / バンドルパス)
//    2. LiveProcess.appex を NSExtension として起こせるか
//       (LaunchAppExtension は既に ShareExtension を起こしているので、
//        同じ機構が LiveProcess にも通るかどうか)
//    3. 起こしたプロセスが生き続けるか、すぐ落ちるか
//
//  結果の見方:
//    「ファイル」アプリ > このデバイス内 > LiveContainer > LCProbe.txt
//    実行のたびに追記される。App Group の UserDefaults にも最後の 1 回分が残る。
//
//  検証が済んだらこのファイルごと削除してよい。
//

import AppIntents
import Foundation

private struct LCProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@available(iOS 17.0, *)
// AlarmKit の stopIntent / secondaryIntent は LiveActivityIntent を要求する。
// ゲスト側が同じマングル名の型を stopIntent に渡せるよう、こちらも合わせる。
// LiveActivityIntent は AppIntent を継承しているので、ショートカットからも
// これまでどおり実行できる。
struct LCProbeHeadlessLaunch: LiveActivityIntent {
    static var title: LocalizedStringResource { "Probe Headless Launch" }
    static var description: IntentDescription {
        IntentDescription("Starts a guest app through LiveProcess without showing any UI. The guest does its work and exits by itself. Writes a log to LiveContainer/LCProbe.txt.")
    }

    /// 画面を出さないことがこのプローブの主眼なので false 固定。
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Guest Bundle ID")
    var guestBundleID: String

    /// 空ならゲストの LCAppInfo.plist の LCDataUUID を使う。
    @Parameter(title: "Container Folder Name (optional)", default: "")
    var containerName: String

    /// 起動後に生存を観測する秒数。
    ///
    /// **通常の運用では 0 のままでよい。** 0 なら起動を投げて即座に返る。
    /// ゲストは自分で処理して終了するので、待つ必要はない。
    /// ショートカットの自動化に組む場合、待たないほうが速い。
    ///
    /// 1 以上にすると、その秒数だけ 1 秒ごとに生存を記録する (調査用)。
    /// App Intent には実行時間の制限があり、30 秒は完走、60 秒は失敗した。
    @Parameter(title: "Observe Seconds (0 = 待たない)", default: 0)
    var observeSeconds: Int

    /// 起動した NSExtension の保持先。
    /// ローカル変数だけだと ARC が早期に解放して、リクエストごと
    /// 取り消される恐れがある (LaunchAppExtension.swift も同じ理由で static)。
    static var heldExtension: NSExtension? = nil

    // MARK: - 収集した内容の記録先

    /// 一度きりのプローブなので、状態は全部ローカル変数で持つ。
    private final class Report {
        var lines: [String] = []
        func add(_ line: String) {
            lines.append(line)
            NSLog("[LCProbe] \(line)")
        }
        var text: String { lines.joined(separator: "\n") }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let report = Report()
        let started = Date()

        let stamp = ISO8601DateFormatter().string(from: started)
        report.add("==================================================")
        report.add("LCProbeHeadlessLaunch  \(stamp)")
        report.add("==================================================")

        // --- 1. 自分がどこで動いているか --------------------------------
        report.add("[実行プロセス]")
        report.add("  pid           = \(getpid())")
        report.add("  processName   = \(ProcessInfo.processInfo.processName)")
        report.add("  bundleID      = \(Bundle.main.bundleIdentifier ?? "(nil)")")
        report.add("  bundlePath    = \(Bundle.main.bundlePath)")
        report.add("  LC_HOME_PATH  = \(ProcessInfo.processInfo.environment["LC_HOME_PATH"] ?? "(未設定)")")

        // --- 2. App Group と共有 UserDefaults ---------------------------
        guard
            let appGroupId = LCSharedUtils.appGroupID(),
            let lcSharedDefaults = UserDefaults(suiteName: appGroupId)
        else {
            report.add("[中断] App Group が見つかりません。LiveContainer の署名を確認してください")
            _ = Self.writeReport(report.text, docURL: nil, defaults: nil)
            throw LCProbeError(report.text)
        }
        report.add("  appGroupID    = \(appGroupId)")

        // --- 3. LiveContainer の Documents を security-scoped で開く -----
        //
        // LaunchAppExtension は自分のコンテナしか触れないので、
        // LiveContainer 本体が保存しておいたブックマークを解決して使う。
        // (LaunchAppExtension.swift と同じ手順)
        var docURL: URL? = nil
        if let bookmarkData = lcSharedDefaults.data(forKey: "LCLaunchExtensionPrivateDocBookmark") {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
                if url.startAccessingSecurityScopedResource() {
                    docURL = url
                    report.add("[Documents] \(url.path)")
                    report.add("  isStale     = \(isStale)")

                    // 【v9 で追加。これが抜けていたのが「アプリが見つからない」原因】
                    //
                    // LCSharedUtils.findBundleWithBundleId: は
                    //     getenv("LC_HOME_PATH")/Documents/Applications/<bundleId>
                    // を見に行く。この環境変数はゲストプロセスでは LCBootstrap が
                    // 設定するが、**拡張プロセスでは誰も設定しない**。
                    // 本家 LaunchAppExtension.swift もブックマーク解決の直後に
                    // 同じことをしている。
                    let lcHome = url.deletingLastPathComponent().path
                    setenv("LC_HOME_PATH", (lcHome as NSString).utf8String, 1)
                    report.add("  LC_HOME_PATH を設定 = \(lcHome)")
                } else {
                    report.add("[Documents] startAccessingSecurityScopedResource に失敗")
                }
            } catch {
                report.add("[Documents] ブックマークの解決に失敗: \(error)")
            }
        } else {
            report.add("[Documents] LCLaunchExtensionPrivateDocBookmark がありません")
            report.add("  LiveContainer を一度起動すると保存されます")
        }
        defer { docURL?.stopAccessingSecurityScopedResource() }

        let lcHomePath = docURL?.deletingLastPathComponent().path

        // --- 4. ゲストアプリの所在とコンテナを調べる --------------------
        //
        // findBundle は getenv("LC_HOME_PATH") に依存するので、
        // それとは別に FileManager で直接も確かめる (裏取り)。
        var resolvedContainer: String? = containerName.isEmpty ? nil : containerName

        // 4a. Applications/ の中身を並べる。
        //     「バンドルフォルダ」の綴りをそのまま目で確認できるようにする。
        //     入力すべきは bundle ID ではなく **フォルダ名** (末尾 .app) である点に注意。
        if let docURL {
            let appsDir = docURL.appendingPathComponent("Applications", isDirectory: true)
            report.add("[Applications] \(appsDir.path)")
            if let names = try? FileManager.default.contentsOfDirectory(atPath: appsDir.path) {
                if names.isEmpty {
                    report.add("  (空)")
                } else {
                    for name in names.sorted() {
                        let mark = (name == guestBundleID) ? "  ← 指定された値と一致" : ""
                        report.add("  - \(name)\(mark)")
                    }
                }
            } else {
                report.add("  一覧を取得できません")
            }

            // 4b. 指定された名前がそのまま存在するか
            let direct = appsDir.appendingPathComponent(guestBundleID)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDir)
            report.add("  直接確認: \(exists ? "存在する" : "存在しない") (isDirectory=\(isDir.boolValue))")
            report.add("    \(direct.path)")
        }

        // 4c. LiveContainer 本体と同じ方法でも探す
        var isSharedApp = false
        if let appBundle = LCSharedUtils.findBundle(withBundleId: guestBundleID,
                                                    isSharedAppOut: &isSharedApp) {
            report.add("[ゲスト] \(guestBundleID)")
            report.add("  findBundle  = 成功")
            report.add("  bundlePath  = \(appBundle.bundlePath)")
            report.add("  isSharedApp = \(isSharedApp)")

            let infoPath = (appBundle.bundlePath as NSString).appendingPathComponent("LCAppInfo.plist")
            if let data = FileManager.default.contents(atPath: infoPath),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                report.add("  LCDataUUID  = \(info["LCDataUUID"] as? String ?? "(なし)")")
                if resolvedContainer == nil {
                    resolvedContainer = info["LCDataUUID"] as? String
                }
            } else {
                report.add("  LCAppInfo.plist を読めません: \(infoPath)")
            }
        } else {
            report.add("[ゲスト] \(guestBundleID)")
            report.add("  findBundle  = 失敗")
            report.add("  上の Applications 一覧にある **フォルダ名** (末尾 .app) を入れてください")
        }
        report.add("  container   = \(resolvedContainer ?? "(未解決)")")

        // --- 5. LiveProcess.appex を起こす ------------------------------
        //
        // ここが本題。LaunchAppExtension は ShareExtension を同じ方法で
        // 起こしているので、機構としては通るはず。
        // 相手が LiveProcess でも同様かを確かめる。
        guard let selfBundleID = Bundle.main.bundleIdentifier else {
            report.add("[中断] 自分の bundle ID が取れません")
            _ = Self.writeReport(report.text, docURL: docURL, defaults: lcSharedDefaults)
            throw LCProbeError(report.text)
        }
        // com.kdt.livecontainer.<TEAM>.LaunchAppExtension
        //   → com.kdt.livecontainer.<TEAM>
        //   → com.kdt.livecontainer.<TEAM>.LiveProcess
        //
        // LaunchAppExtension.swift が ShareExtension を組み立てているのと同じ書き方。
        let liveProcessID = ((selfBundleID as NSString).deletingPathExtension as NSString)
            .appendingPathExtension("LiveProcess")
        report.add("[LiveProcess] identifier = \(liveProcessID)")

        // 【v9】static に保持する。
        //   LaunchAppExtension.swift も `static var ext: NSExtension?` に
        //   持たせている。ローカル変数のままだと、ARC が早めに解放した場合に
        //   リクエストごと取り消されて子プロセスが落ちる恐れがある。
        //   1 秒で終了していた原因の候補のひとつ。
        var ext: NSExtension
        do {
            ext = try NSExtension(identifier: liveProcessID)
            Self.heldExtension = ext
            report.add("  NSExtension の生成: 成功 (static に保持)")
        } catch {
            report.add("  NSExtension の生成: 失敗 — \(error)")
            report.add("")
            report.add("【判定】拡張プロセスから LiveProcess を起こせません。")
            report.add("  インストール時に App Extension が削がれている可能性があります。")
            report.add("  SideStore なら \"Keep App Extensions (Use Main Profile)\" を選んでください。")
            _ = Self.writeReport(report.text, docURL: docURL, defaults: lcSharedDefaults)
            throw LCProbeError(report.text)
        }

        // 起動したプロセスの終了理由を受け取る。
        //
        // 【v11】キャンセル通知も拾うようにした。
        //
        //   LCBootstrap.m は invokeAppMain が失敗したとき、LiveProcess では
        //   エラー文字列を cancelRequestWithError: で返してくる。
        //
        //     NSString *appError = invokeAppMain(...);
        //     if (appError) {
        //         if (isLiveProcess) {
        //             [context cancelRequestWithError:
        //                 [NSError ... userInfo:@{NSLocalizedDescriptionKey: appError}]];
        //             exit(1);
        //         }
        //     }
        //
        //   v10 までは setRequestInterruptionBlock しか設定していなかったため、
        //   この文字列を取りこぼしていた。直近の実測で interrupted = false が
        //   続いていたのは、中断ではなくキャンセルの経路だったから。
        let outcome = LaunchOutcome()
        ext.setRequestInterruptionBlock { _ in
            outcome.markInterrupted()
        }
        ext.setRequestCancellationBlock { _, error in
            outcome.markCancelled(error)
        }

        // --- 5b. userInfo を組み立てる ----------------------------------
        //
        // 【v12】本家 MultitaskSupport/AppSceneViewController.m と同じ形にした。
        //
        //   v11 までは hostUrlScheme を渡していなかった。その結果:
        //
        //     // LCBootstrap.m:341
        //     if (isLiveProcess && !isSideStore) {
        //         lcAppUrlScheme = [lcUserDefaults stringForKey:@"hostUrlScheme"];  // nil
        //     }
        //     ...
        //     // LCSharedUtils.m:286
        //     info[folderName] = @{ @"runningLC": lc, ... };   // ← nil で例外
        //
        //   実測したスタックがまさにこれだった。
        //
        //     +[LCSharedUtils setContainerUsingByLC:folderName:auditToken:] + 324
        //       ← invokeAppMain + 4584
        //         ← LiveContainerMain + 2320
        //           ← LiveProcessMain + 1244
        //
        //   RefreshHandler (SideStore) がこのキーを渡していないのは、
        //   isSideStore が true になって上の分岐を通らないため。
        //   通常のゲストを起こすときだけ必要になる。
        //
        //   ブックマークも本家に合わせた。オプション 1<<11 は LiveContainer が
        //   使っている値で、単なる [] では権限が渡らない可能性がある。
        //   対象も Documents 全体ではなく、本家と同じ 3 つ
        //   (アプリバンドル / コンテナ / Tweaks) にする。
        let bookmarkOptions = URL.BookmarkCreationOptions(rawValue: 1 << 11)

        var userInfo: [String: Any] = [:]
        userInfo["selected"] = guestBundleID
        if let resolvedContainer { userInfo["selectedContainer"] = resolvedContainer }
        if let lcHomePath { userInfo["lcHomePath"] = lcHomePath }

        // hostUrlScheme — これが無いと invokeAppMain が nil 例外で落ちる。
        // 空いている LiveContainer のスキームを選ぶ。
        let hostScheme = Self.pickHostScheme()
        userInfo["hostUrlScheme"] = hostScheme
        report.add("  hostUrlScheme = \(hostScheme)")

        var bookmarks: [Data] = []
        if let docURL, let resolvedContainer {
            let appURL = docURL
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(guestBundleID, isDirectory: true)
            let dataURL = docURL
                .appendingPathComponent("Data/Application/\(resolvedContainer)", isDirectory: true)
            let tweaksURL = docURL.appendingPathComponent("Tweaks", isDirectory: true)

            // 【v13→v14】ホストの Library/Sounds について。
            //
            //   AlarmKit の `.named(_:)` で指定するカスタム音源は、
            //   鳴動時にシステムデーモンが **ホストのコンテナ配下**
            //   <LC_HOME_PATH>/Library/Sounds から読む。
            //   ゲストが音源を差し替えるには、そこへの書き込みが要る。
            //
            //   v13 では拡張側でブックマークを作ったが、ゲストからの書き込みが
            //   NSCocoaErrorDomain code=513 (権限なし) で失敗した。
            //   security-scoped bookmark は「自分が持っている権限」しか渡せず、
            //   LaunchAppExtension は Documents しか持っていないため。
            //
            //   v14 では本体が作ったものを転送する (下の LCLibrarySoundsBookmark)。
            //   ここでは診断のため、拡張自身が書けるかどうかだけ確かめる。
            let soundsURL = docURL
                .deletingLastPathComponent()      // <LC_HOME_PATH>
                .appendingPathComponent("Library/Sounds", isDirectory: true)
            report.add("  Library/Sounds = \(soundsURL.path)")
            report.add("    存在: \(FileManager.default.fileExists(atPath: soundsURL.path) ? "あり" : "なし")")

            // 拡張自身が書けるか (書けないのが想定どおり)
            let extProbe = soundsURL.appendingPathComponent(".ext-write-probe")
            do {
                try Data([0x41]).write(to: extProbe)
                try? FileManager.default.removeItem(at: extProbe)
                report.add("    拡張からの書き込み: できる")
            } catch {
                let ns = error as NSError
                report.add("    拡張からの書き込み: できない (\(ns.domain) code=\(ns.code))")
            }

            let targets: [(String, URL)] = [
                ("アプリ", appURL),
                ("コンテナ", dataURL),
                ("Tweaks", tweaksURL),
            ]
            for (label, url) in targets {
                if let data = try? url.bookmarkData(options: bookmarkOptions,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
                    bookmarks.append(data)
                } else {
                    report.add("  bookmark 失敗: \(label) — \(url.path)")
                }
            }

            // 【v14】Library/Sounds は **本体が作ったブックマーク**を転送する。
            //
            //   v13 では拡張側で作っていたが、ゲストからの書き込みが
            //   NSCocoaErrorDomain code=513 (権限なし) で失敗した。
            //
            //   security-scoped bookmark は「自分が持っている権限」しか渡せない。
            //   LaunchAppExtension が持っているのは Documents のブックマークだけで、
            //   Library/Sounds はその外側にある。だから生成自体は成功しても
            //   権限が伴わなかった。
            //
            //   LiveContainer 本体 (LCTabView.checkSoundsBookmark) が起動時に
            //   作って App Group に置くようにしたので、ここでは読むだけ。
            //   Documents のブックマークと同じ流れになる。
            if let soundsBookmark = lcSharedDefaults.data(forKey: "LCLibrarySoundsBookmark") {
                bookmarks.append(soundsBookmark)
                report.add("  Library/Sounds = 本体のブックマークを転送")

                // 参考情報: 解決先を確かめておく
                var isStale = false
                if let resolved = try? URL(resolvingBookmarkData: soundsBookmark,
                                           bookmarkDataIsStale: &isStale) {
                    report.add("    解決先 = \(resolved.path)  isStale=\(isStale)")
                } else {
                    report.add("    解決できません (壊れている可能性)")
                }
            } else {
                report.add("  Library/Sounds = 本体のブックマークがありません")
                report.add("    LiveContainer 本体を一度起動すると作られます")
            }
        }
        if bookmarks.isEmpty, let docURL,
           let fallback = try? docURL.bookmarkData(options: bookmarkOptions,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) {
            // 個別に取れなかった場合は Documents 全体で代用する
            bookmarks.append(fallback)
            report.add("  bookmarks   = Documents 全体で代用")
        }
        userInfo["bookmarks"] = bookmarks
        report.add("  bookmarks   = \(bookmarks.count) 件を同梱")

        let item = NSExtensionItem()
        item.userInfo = userInfo

        let beginAt = Date()
        let uuid = await ext.beginRequest(withInputItems: [item])
        let beginElapsed = Date().timeIntervalSince(beginAt)
        report.add("  beginRequest: 完了 (\(String(format: "%.2f", beginElapsed)) 秒)")
        report.add("  requestUUID = \(uuid)")

        let pid = ext.pid(forRequestIdentifier: uuid)
        report.add("  pid         = \(pid)")

        if pid <= 0 {
            // キャンセル通知は非同期に来るので、少しだけ待ってから記録する。
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            report.add("")
            report.add("【判定】プロセスが起動しませんでした。")
            report.add("[終了理由] \(outcome.summary ?? "通知なし")")
            ext._kill(9)
            Self.heldExtension = nil
            _ = Self.writeReport(report.text, docURL: docURL, defaults: lcSharedDefaults)
            return .result(dialog: IntentDialog(stringLiteral: "起動失敗 (pid=\(pid))\n\(outcome.summary ?? "")"))
        }

        // --- 6. 生存を観測する ------------------------------------------
        //
        // 【v10】判定を 3 系統にした。
        //
        //   v9 では getpgid(pid) > 0 だけで判定していたが、
        //   「+1s alive=false なのに interrupted = false」という矛盾が出た。
        //   setRequestInterruptionBlock は子プロセスが落ちたときに
        //   NSExtension が呼ぶコールバックなので、それが発火していないなら
        //   リクエストは生きている可能性が高い。
        //
        //   getpgid は、拡張プロセスのサンドボックスでは他プロセスに対して
        //   EPERM で弾かれることがある。その場合 -1 が返り、生きていても
        //   「死んだ」と誤判定する。RefreshHandler も同じ判定を使っているが、
        //   あちらはアプリ本体プロセスから呼んでいるので条件が違う。
        //
        //   そこで:
        //     1. kill(pid, 0) の errno   … ESRCH なら本当に死亡、EPERM なら生存
        //     2. pid(forRequestIdentifier:) … NSExtension に聞き直す (最も信頼できる)
        //     3. getpgid                  … 比較用に残す
        //
        //   また alive=false でも打ち切らず、指定秒数ぶん最後まで観測する。
        // observeSeconds = 0 なら待たずに返す (通常の運用)。
        //
        //   ゲストは自分で処理して exit(0) するので、こちらが待つ理由はない。
        //   ショートカットの自動化に組む場合、待たないほうが速く、
        //   App Intent の実行時間制限にも当たらない。
        if observeSeconds <= 0 {
            report.add("[生存確認] 省略 (Observe Seconds = 0)")
            report.add("")
            report.add("【判定】起動を投げました。結果はゲスト側のログで確認してください。")
            report.add("  AlarmClock なら:")
            report.add("    ファイル > LiveContainer > Data > Application > <コンテナUUID>")
            report.add("             > Documents > AlarmClockLaunched.txt")
            report.add("")
            Self.heldExtension = nil
            let where0 = Self.writeReport(report.text, docURL: docURL, defaults: lcSharedDefaults)
            return .result(dialog: IntentDialog(stringLiteral: "起動しました (pid=\(pid))\n記録先: \(where0)"))
        }

        report.add("[生存確認] \(observeSeconds) 秒間、1 秒ごと")
        report.add("  kill(pid,0) の errno: ESRCH=\(ESRCH) は死亡、EPERM=\(EPERM) は生存(権限なし)")

        // 【v16】App Intent の実行時間制限を測る。
        //
        //   Observe Seconds = 8 は成功、60 は
        //   「不明なエラーが発生したため実行できませんでした」で失敗した。
        //   その間のどこかに上限があるが公開されていないので実測する。
        //
        //   打ち切られると perform() ごと消えるため、最後にまとめて書く方式では
        //   何も残らない。そこで **1 秒ごとにファイルへ追記**し、
        //   最後に書けた秒数を上限の下界とする。
        //
        //   さらに、打ち切りが「Task のキャンセル」なのか
        //   「プロセスごと強制終了」なのかを分けるため、
        //   Task.isCancelled と CancellationError も見る。
        //     キャンセルなら記録が残る → 後片付けの余地がある
        //     何も残らない             → 強制終了。何もできない
        report.add("  ★ 1 秒ごとにこのファイルへ追記します (打ち切られても記録が残る)")
        Self.appendTick(report.text, docURL: docURL, defaults: lcSharedDefaults)

        var lastVerdictAlive = false
        var aliveSeconds = 0
        var cancelledDuringObserve = false

        for i in 1...max(1, observeSeconds) {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch is CancellationError {
                // ★ ここに来たら「キャンセルされた」と確定する
                cancelledDuringObserve = true
                report.add("  +\(i)s  ★ CancellationError を捕捉 (Task がキャンセルされた)")
                Self.appendTick(report.text, docURL: docURL, defaults: lcSharedDefaults)
                break
            } catch {
                report.add("  +\(i)s  sleep が失敗: \(error)")
            }

            if Task.isCancelled {
                cancelledDuringObserve = true
                report.add("  +\(i)s  ★ Task.isCancelled = true")
                Self.appendTick(report.text, docURL: docURL, defaults: lcSharedDefaults)
                break
            }

            // 1. kill(pid, 0)
            errno = 0
            let killResult = kill(pid, 0)
            let killErrno = errno
            let killSays: String
            let killAlive: Bool
            if killResult == 0 {
                killSays = "生存 (シグナル送信可)"
                killAlive = true
            } else if killErrno == EPERM {
                killSays = "生存 (EPERM: 権限なし)"
                killAlive = true
            } else if killErrno == ESRCH {
                killSays = "死亡 (ESRCH)"
                killAlive = false
            } else {
                killSays = "不明 (errno=\(killErrno))"
                killAlive = false
            }

            // 2. NSExtension に聞き直す
            let reportedPid = ext.pid(forRequestIdentifier: uuid)
            let extAlive = reportedPid > 0

            // 3. getpgid (v9 と同じ判定)
            errno = 0
            let pgid = getpgid(pid)
            let pgidErrno = errno

            // 総合判定: NSExtension と kill のどちらかが生存と言えば生存とみなす。
            // 中断 / キャンセルの通知が来ていたらそちらを優先する (最も確度が高い)。
            let alive = !outcome.isFinished && (extAlive || killAlive)
            if alive { aliveSeconds = i }
            lastVerdictAlive = alive

            report.add("  +\(i)s  総合=\(alive ? "生存" : "死亡")"
                       + "  kill=\(killSays)"
                       + "  ext.pid=\(reportedPid)"
                       + "  getpgid=\(pgid)\(pgid <= 0 ? "(errno=\(pgidErrno))" : "")"
                       + (outcome.summary.map { "  ← \($0)" } ?? ""))

            // ★ 毎秒書き出す。打ち切られてもここまでの記録が残る。
            //   最後に書けた行の秒数が、実行時間制限の下界になる。
            Self.appendTick(report.text, docURL: docURL, defaults: lcSharedDefaults)
        }

        // --- 7. 判定 ----------------------------------------------------
        report.add("")
        let verdict: String
        if aliveSeconds >= max(1, observeSeconds) {
            verdict = "成功: ゲストが画面なしで \(observeSeconds) 秒間動き続けました"
            report.add("【判定】\(verdict)")
            report.add("  この経路でヘッドレス実行が可能です。")
            report.add("  次はゲスト側の起動処理を、シーンに依存しない場所")
            report.add("  (App.init() や UIApplicationDelegate) に移す段階になります。")
        } else if aliveSeconds > 0 && lastVerdictAlive {
            verdict = "断続的に生存と判定されました (最終時点では生存)"
            report.add("【判定】\(verdict)")
            report.add("  観測方法によって結果が割れています。上の各行を比較してください。")
        } else if aliveSeconds > 0 {
            verdict = "起動はしたが \(aliveSeconds) 秒で終了しました"
            report.add("【判定】\(verdict)")
            report.add("  ゲスト側が起動直後に落ちている可能性があります。")
            report.add("  シーンが繋がらないことが原因かもしれません。")
        } else {
            verdict = "起動直後に終了しました"
            report.add("【判定】\(verdict)")
            report.add("  kill の errno が ESRCH なら本当に落ちています。")
        }

        // 【v11】終了理由。キャンセルなら invokeAppMain が返した文字列が入る。
        report.add("")
        report.add("[終了理由]")
        if let summary = outcome.summary {
            report.add("  \(summary)")
            if outcome.isCancelled {
                report.add("")
                report.add("  ↑ これが LiveContainer 側の invokeAppMain() が返したエラーです。")
                report.add("  LCBootstrap.m は LiveProcess で失敗したとき、")
                report.add("  cancelRequestWithError: にこの文字列を載せて返します。")
            }
        } else {
            report.add("  通知なし (中断もキャンセルも来ていない)")
            report.add("  ゲストが正常に終了したか、通知が届く前に観測を終えた可能性があります。")
        }
        report.add("  interrupted = \(outcome.isInterrupted)  cancelled = \(outcome.isCancelled)")
        report.add("  所要時間     = \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒")

        // 【v16】実行時間制限の計測結果
        report.add("")
        report.add("[実行時間]")
        report.add("  観測を指示された秒数 = \(observeSeconds)")
        report.add("  実際に観測できた秒数 = \(aliveSeconds > 0 ? aliveSeconds : 0)")
        if cancelledDuringObserve {
            report.add("  ★ 観測中に Task がキャンセルされました")
            report.add("    App Intent の実行時間制限に達したと思われます。")
            report.add("    キャンセルとして届くので、後片付けは可能です。")
        } else {
            report.add("  最後まで観測できました (この秒数では制限に達していない)")
        }
        report.add("")

        // 後片付け。観測が目的なので必ず止める。
        ext._kill(9)
        Self.heldExtension = nil
        report.add("[終了] _kill(9) を送信し、保持を解放しました")
        report.add("")

        let where_ = Self.writeReport(report.text, docURL: docURL, defaults: lcSharedDefaults)
        let dialogText = outcome.summary.map { "\(verdict)\n\($0)" } ?? verdict
        return .result(dialog: IntentDialog(stringLiteral: "\(dialogText)\n記録先: \(where_)"))
    }

    // MARK: - 記録

    /// 【v16】途中経過を書き出す。
    ///
    /// 打ち切られると `perform()` ごと消えるので、最後にまとめて書く方式では
    /// 何も残らない。1 秒ごとにこれを呼び、そこまでの内容で上書きしておく。
    ///
    /// 追記ではなく上書きなのは、`writeReport` が最後にもう一度
    /// 全体を追記するため。二重に残るのを避ける。
    /// 打ち切られた場合は、この途中経過だけがファイルに残る。
    private static func appendTick(_ text: String, docURL: URL?, defaults: UserDefaults?) {
        defaults?.set(text, forKey: "LCProbeInProgress")
        guard let docURL else { return }
        let url = docURL.appendingPathComponent("LCProbe-progress.txt")
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// `hostUrlScheme` に渡す LiveContainer のスキームを選ぶ。
    ///
    /// `setContainerUsingByLC:` はこの値をコンテナロックに書き込むので、
    /// **インストール済みかつ使用中でないもの**を選ぶ。
    /// LaunchAppExtension.swift の `forEachInstalledLC(isFree: true)` と同じ条件。
    ///
    /// 全部埋まっていたら先頭で妥協する
    /// (プローブは短時間で終わるので、実害は小さい)。
    private static func pickHostScheme() -> String {
        let schemes = LCSharedUtils.lcUrlSchemes() ?? ["livecontainer"]
        for scheme in schemes {
            guard let url = URL(string: "\(scheme)://"),
                  lsApplicationWorkspaceCanOpenURL(url) else {
                continue
            }
            if LCSharedUtils.isLCScheme(inUse: scheme) {
                continue
            }
            return scheme
        }
        return schemes.first ?? "livecontainer"
    }

    /// レポートを追記して、書けた場所を返す。
    private static func writeReport(_ text: String, docURL: URL?, defaults: UserDefaults?) -> String {
        defaults?.set(text, forKey: "LCProbeLastReport")

        guard let docURL else {
            return "App Group の UserDefaults のみ (LCProbeLastReport)"
        }
        let fileURL = docURL.appendingPathComponent("LCProbe.txt")
        let chunk = text + "\n"
        do {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(chunk.utf8))
            } else {
                try chunk.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            return "LiveContainer/LCProbe.txt"
        } catch {
            NSLog("[LCProbe] 書き込み失敗: \(error)")
            return "書き込み失敗 (\(error.localizedDescription))"
        }
    }
}

/// 中断 / キャンセルのコールバックはいつ呼ばれるか分からないので、参照型で受ける。
///
/// 区別が重要:
///   中断 (interruption)  … 子プロセスが不意に落ちた
///   キャンセル (cancellation) … LiveProcess が cancelRequestWithError: を呼んだ。
///                              **invokeAppMain のエラー文字列が入っている**
private final class LaunchOutcome: @unchecked Sendable {
    private var interrupted = false
    private var cancelled = false
    private var errorDescription: String? = nil
    private var errorDomainCode: String? = nil
    private let lock = NSLock()

    func markInterrupted() {
        lock.lock(); interrupted = true; lock.unlock()
    }

    func markCancelled(_ error: Error?) {
        lock.lock()
        cancelled = true
        if let ns = error as NSError? {
            errorDescription = ns.localizedDescription
            errorDomainCode = "\(ns.domain) code=\(ns.code)"
        }
        lock.unlock()
    }

    var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// 「終わった」とみなせるか (中断でもキャンセルでも)
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted || cancelled
    }

    /// レポートに出す 1 行。まだ何も起きていなければ nil。
    var summary: String? {
        lock.lock(); defer { lock.unlock() }
        if cancelled {
            let detail = errorDescription ?? "(説明なし)"
            let dc = errorDomainCode ?? "(不明)"
            return "キャンセル: \(detail)  [\(dc)]"
        }
        if interrupted {
            return "中断 (子プロセスが不意に終了)"
        }
        return nil
    }
}
