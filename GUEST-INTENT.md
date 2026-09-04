# LCGuestIntent

本家 LiveContainer との差分は **`LiveContainer/LCGuestIntent.swift` の追加のみ**です
(あとは `.github/` のビルド用ファイル)。

- 既存ファイルの変更: **ゼロ**
- `Info.plist` の変更: **ゼロ**
- 実コード: **47 行**

`project.pbxproj` はリポジトリでは変更していません。CI が
`.github/scripts/add_guest_intent.py` でパッチします。Mac がなくても
GitHub の web UI だけで完結します。

---

## 何を解決するか

ゲストアプリの App Intents は installd に登録されません。索引されるのは
`LiveContainer.app` の `Metadata.appintents` だけで、ゲストのバンドルは
走査対象に入りません。

そのため「**登録済みの** `LiveActivityIntent`」を要求するシステム機能が
ゲストから一切使えません。

| 使えないもの |
|---|
| AlarmKit の `stopIntent` / `secondaryIntent` |
| WidgetKit の `Button(intent:)` / `Toggle(intent:)` |
| ControlWidget のアクション |

AlarmKit には実害もあります。`secondaryButtonBehavior = .custom` は Intent 自身が
`stop()` を呼ばないと鳴り止まないため、解決されないと**アラームを止められません**。

---

## 他に道がないことは実測済み

2026-09-04 / iPadOS 26 / iPad 9th generation

| 試した経路 | 結果 |
|---|---|
| ゲストが宣言した `LiveActivityIntent` | 解決されない |
| App Intents 拡張に宣言した `LiveActivityIntent` | 解決されない |
| 背景の app プロセスから `NSExtension` で `LiveProcess.appex` を起こす | 起こせない |
| `BGContinuedProcessingTask` のハンドラから同上 | **起こせない** |

4 つ目が決め手です。システムが正規のバックグラウンド実行アサーションを
与えた状態でも `beginExtensionRequestWithInputItems:` の completion が
nil UUID を返し、cancellation の通知すら来ません。マルチタスク (前面) では
同じ経路が動くので、条件は「アサーションの有無」ではなく「前面かどうか」です。

**ゲストのプロセスを背景から起こす手段は存在しません。**
残るのは「LiveContainer のプロセスでゲストのコードを実行する」道だけです。

---

## この実装がすること

**`RTLD_DEFAULT` からシンボルを引いて呼ぶ。それだけです。**

```swift
guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), handler) else { … }

typealias GuestEntry =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
let call = unsafeBitCast(symbol, to: GuestEntry.self)
let result = action.withCString { a in payload.withCString { p in call(a, p) } }
```

**dylib の読み込みはしません。** 既存の Tweaks 機構が担います。

```objc
// LCBootstrap.m
if ([lcUserDefaults boolForKey:@"LCLoadTweaksToSelf"]) {
    setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);
    dlopen("@executable_path/Frameworks/TweakLoader.dylib", RTLD_LAZY);
}
```

これは `LiveContainerSwiftUIMain()` の直前なので、Intent のために背景起動された
場合にも通ります。つまり `perform()` の時点で dylib は既にプロセス内にあり、
**新しい注入経路は追加していません**。既にある機能の出口を 1 つ作るだけです。

`action` と `payload` の中身は解釈せず、そのまま渡します。

---

## ゲスト側に必要なもの

**1. 構造の一致するスタブ**

```swift
@available(iOS 17.0, *)
struct LCGuestIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "LiveContainer Guest Action"
    static var isDiscoverable  = false
    static var openAppWhenRun  = false
    static var persistentIdentifier: String { "com.kdt.livecontainer.guestIntent" }

    @Parameter(title: "Handler Symbol") var handler: String
    @Parameter(title: "Action")         var action:  String
    @Parameter(title: "Payload")        var payload: String

    init() { handler = ""; action = ""; payload = "" }
    init(handler: String, action: String = "", payload: String = "") {
        self.handler = handler; self.action = action; self.payload = payload
    }
    func perform() async throws -> some IntentResult { .result() }   // 呼ばれない
}
```

`persistentIdentifier` が一致していれば解決されます。Swift のマングル名は
一致しなくて構いません (ホスト = `LiveContainer`、ゲスト = 各アプリの
モジュール名で実測確認済み)。

**2. エントリを公開した dylib**

```swift
@_cdecl("MyAppGuestPerform")
public func MyAppGuestPerform(
    _ action: UnsafePointer<CChar>?,
    _ payload: UnsafePointer<CChar>?
) -> Int32
```

`DEAD_CODE_STRIPPING = NO` が要ります。dylib 内から誰も呼ばないので削られます。

シンボル名はアプリ固有にしてください。`RTLD_DEFAULT` は先勝ちなので、
複数のアプリが同じ名前を名乗ると衝突します。

**3. ユーザー操作**

```
1. LiveContainer > 調整 > 「調整をインポート」でグローバルフォルダに置く
2. 調整タブ右上の署名ボタンで署名する
3. 設定画面最下部のバージョン表示を 5 回タップして開発者モードを出す
4. 「Load Tweaks to LiveContainer Itself」を有効にする
5. LiveContainer を開き直す
```

CI 製の dylib は未署名で、`LCLoadTweaksToSelf` の経路には署名検証の迂回が
ありません (ゲストアプリとは異なります)。手順 2 を省くと
`missing code signature` で読み込めません。

---

## 前例

**1. `LiveProcess/main.m` の `customPayloadDylib` / `customPayloadEntry`**

渡された名前の dylib を `dlopen` し、渡された名前の関数を `dlsym` して呼びます。
**同じ設計**で、しかもあちらは `dlopen` までしています。ただし実行場所は
LiveProcess の子プロセスで、上の実測どおり背景からは到達できません。

**2. `LiveContainer/Info.plist` の 33 件の UsageDescription**

すべて "The guest app is requesting for this permission."。
「ゲストが要求するものをホストが代表して宣言する」は確立した方針です。

**3. `NSBonjourServices` の `_FC9F5ED42C8A._tcp`**

特定のゲストアプリのためのサービス種別。汎用でない項目を足す前例です。

**4. `.github/build_github.sh` の `Metadata.appintents` 移植**

第三者 (SideStore) の App Intents をホストのバンドルに登録させ、Swift の
マングル名を `sed` で書き換えています。App Intents そのものの前例です。

---

## リスク

`customPayloadDylib` は LiveProcess の**子プロセス**で走るので、壊れても
LiveContainer 本体は無事です。こちらは**ホスト本体**で走るためリスクの質が
違います。以下で抑えています。

- LiveContainer は dylib を読み込まない。読み込むかどうかはユーザーの既存の設定
- `RTLD_DEFAULT` に既にあるシンボルしか呼ばない
- 見つからなければ静かに終わる

---

## 実測

停止ボタンから **14 ms** でゲストのコードが走ります。アプリは開かず、
画面も点きません。

```
invoked handler=AlarmClockGuestPerform action=reshuffle
AlarmHandler: 入りました action=reshuffle
AlarmHandler: 差し替えました prepared-1159FEF5-….flac <- Between the Waves….flac
              (候補 18 曲中、履歴により 7 曲を除外)
  AlarmClockGuestPerform result=0
```

---

## PR を出す場合の注意

`project.pbxproj` の変更をコミットする必要があります。手元では CI が
パッチしていますが、PR にはパッチ後の pbxproj を含めてください。

```
python3 .github/scripts/add_guest_intent.py
git add LiveContainer.xcodeproj/project.pbxproj LiveContainer/LCGuestIntent.swift
```

また `.github/scripts/` と `.github/workflows/build-guest-intent.yml` は
検証用なので PR には含めないでください。
