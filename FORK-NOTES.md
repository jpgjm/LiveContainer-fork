# フォーク版メモ

本家 [LiveContainer](https://github.com/LiveContainer/LiveContainer) に対して、
次の 2 点を追加したフォークです。

1. **Quick Share (Nearby Share) のサービスタイプを Bonjour 許可リストに追加**
2. **フォークで完結する IPA ビルド用ワークフローを追加**

---

## 1. なぜサービスタイプの追加が要るのか

LiveContainer はゲストアプリを**ホストのプロセス内で**動かします。
そのため iOS から見える `Info.plist` はホスト (LiveContainer) のものになります。

`Resources/Info.plist` には汎用のプライバシー説明文が一通り用意されているので、
**Local Network の許可も写真ライブラリの許可もゲストで取得でき**、
素の TCP / UDP 通信は問題なく通ります。

しかし `NSBonjourServices` だけは説明文ではなく**サービスタイプの固定リスト**で、
**ゲスト側の `NSBonjourServices` はマージされません**。
リストに無いタイプを登録・探索しようとしたゲストは、次のエラーで拒否されます。

| 症状 | 意味 |
|---|---|
| `NSNetServicesMissingRequiredConfigurationError (-72008)` | publish しようとしたタイプが許可リストに無い |
| `kDNSServiceErr_NoAuth (-65555)` | browse しようとしたタイプが許可リストに無い |
| **権限プロンプトが出ない** | タイプの照合は TCC の手前の構成チェックなので、許可を問う段階に到達しない |

LocalSend が LiveContainer 上で動くのは、宣言している `_http._tcp` が
既に許可リストに含まれているうえ、Bonjour に依存しない HTTP サブネットスキャン
経路も持っているからです。

### 追加した内容

`Resources/Info.plist` の `NSBonjourServices` 配列に 2 行追加しています。

```xml
<string>_FC9F5ED42C8A._tcp</string>
<string>_FC9F5ED42C8A._tcp.</string>
```

`_FC9F5ED42C8A._tcp` は **Google が固定した Quick Share / Nearby Share の
サービスタイプ**で、アプリごとに任意に決められる値ではありません。
QSProbe だけでなく NearDrop 系の実装 (QuickDrop、CrossDrop など) が
共通で使います。

末尾ドットの有無はどちらでも動くことを実機で確認済みですが、
照合の実装がどちらの正規化を使うかに依存しないよう**両方**書いてあります。

仕様上固定である裏づけ:
<https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md>

---

## 2. IPA のビルド

### `.github/workflows/build-ipa.yml` (新規・こちらを使う)

Actions タブ → **Build IPA (fork)** → Run workflow で実行します。
`main` / `master` への push でも走ります。

本家の `build.yml` との違いは次のとおりです。

| | 本家 build.yml | 追加した build-ipa.yml |
|---|---|---|
| リリース処理 | nightly リリースを作る | **行わない** (secrets 不要) |
| SideStore 同梱版 | 作る (外部ダウンロード依存) | **作らない** |
| Xcode / ランナー | 26.2 / macos-latest 固定 | workflow_dispatch から差し替え可 |
| 失敗時 | ログのみ | `build-failure` アーティファクトを収集 |

ビルド前に **`_FC9F5ED42C8A._tcp` が `Info.plist` に入っているかを検証する
ステップ**を入れてあります。ここで落ちたら plist の編集が取り込まれていません。

成果物は `LiveContainer-ipa` アーティファクトの中の `LiveContainer.ipa` です。
ダウンロードして SideStore でインストールしてください
(既存の LiveContainer は置き換えになります)。

### `.github/workflows/build.yml` (本家・手動実行のみに変更)

フォークでは次の理由で毎 push 失敗するため、`on:` を `workflow_dispatch` のみに
絞ってあります。

- `release__nightly` ジョブが push で起動し、リリース作成に失敗する
- `actions/upload-artifact@v7` / `download-artifact@v8` を使っており、
  環境によっては存在しないバージョンになる

本家に追随したい場合は `on:` を元に戻してください。ジョブ本体は変更していません。

### サブモジュールについて (重要)

このリポジトリは 3 つのサブモジュールに依存しています。

| ディレクトリ | 取得元 |
|---|---|
| `OpenSSL` | <https://github.com/krzyzanowskim/OpenSSL> |
| `litehook` | <https://github.com/LiveContainer/litehook> |
| `fishhook` | <https://github.com/LiveContainer/fishhook> |

**GitHub の「Download ZIP」で取得したツリーには、サブモジュールの中身が
入っていません。** ディレクトリが空のまま (あるいは存在しないまま) になります。
その状態を自分のリポジトリへ push すると gitlink も登録されないため、
`actions/checkout` の `submodules: recursive` は何も取得しません。

この状態でビルドすると次のエラーで落ちます。

```
error: There is no XCFramework found at '.../OpenSSL/Frameworks/OpenSSL.xcframework'.
       (in target 'LiveContainer' from project 'LiveContainer')
```

`build-ipa.yml` には **Ensure submodules** ステップを入れてあり、
ディレクトリが空なら直接 clone しにいくので、ZIP 由来のリポジトリでも
そのままビルドできます。

ただし ZIP 由来の場合、サブモジュールは**本家が固定しているコミットではなく
既定ブランチの最新**になります。将来 API が変わって噛み合わなくなる可能性が
あるので、次のどちらかを推奨します。

- **GitHub 上で本家を Fork する** (Fork ボタン)。gitlink が保たれるので
  ピン留めされたコミットが取得され、Ensure submodules は何もしません。
  その後 `Resources/Info.plist` などの変更を加えるのが最も確実です。
- ZIP 運用を続ける場合は、噛み合わなくなったときに workflow_dispatch の
  `openssl_ref` 入力でタグやブランチを指定して回避します。

なお `OpenSSL` はプリビルドの xcframework を含むため clone に時間がかかります
(`--depth 1` を指定済み)。

### XCFramework の署名検証について

Xcode 15 以降は XCFramework の署名を検証します。`LiveContainer.xcodeproj` の
`project.pbxproj` には、OpenSSL の期待される署名が記録されています。

```
expectedSignature = "AppleDeveloperProgram:67RAULRX93:Marcin Krzyzanowski";
```

取得した xcframework の署名がこれと違うと、次のエラーで落ちます。

```
error: “OpenSSL.xcframework” is not signed with the expected identity
       and may have been compromised.
note: Expected team identifier: 67RAULRX93
```

ZIP 由来のリポジトリで OpenSSL の**既定ブランチの最新**を取ってしまうと、
本家が固定しているコミットと署名が食い違ってこうなります。

`build-ipa.yml` は 2 段構えで対処しています。

1. **Ensure submodules** が GitHub API で本家の固定コミット SHA を解決し、
   そのコミットを直接 fetch する。これが成功すれば署名は一致する
2. それでも食い違う場合、**Reconcile XCFramework signature** が実際の署名を
   `codesign -dvv` で確認し、期待値と違えば `expectedSignature` を
   pbxproj から外してビルドを続行する (ログに警告を出す)

2 の挙動が不本意な場合は、workflow_dispatch の
`strict_xcframework_signature` を有効にしてください。一致しない時点で
ビルドを中止します。

なお `expectedSignature` の除去はランナー上のチェックアウトに対してのみ行われ、
リポジトリのファイルは変更されません。

### ビルドが通らない場合

1. `build-failure` アーティファクトの `errors.txt` を見る
   - `No XCFramework found` → サブモジュール。上記「サブモジュールについて」を参照
   - `submodules.txt` に各サブモジュールのファイル数が出るので、0 なら取得失敗
   - `not signed with the expected identity` → 上記「XCFramework の署名検証について」を参照
2. `environment.txt` に載っている Xcode のバージョンを確認する
3. 本家は Xcode 26.2 を固定しているので、`latest-stable` で落ちるなら
   workflow_dispatch の入力で `26.2` を指定して再実行する
4. ランナー側も `macos-15` などに切り替えて試す

---

## 3. 動作確認

1. パッチ版 LiveContainer を SideStore でインストールする
2. その中で Quick Share 系アプリ (QSProbe など) を起動する
3. mDNS の publish が成功し、`-72008` / `-65555` が出ないこと

初回は LiveContainer 本体に対して Local Network の許可ダイアログが出ます。
一度許可すれば、以後どのゲストアプリでも通ります。

---

## 4. 上流に PR を出す場合

許可リストの末尾に `_stikpairprobe._tcp` という特定ツール向けのカスタムタイプが
既に入っているため、**タイプ追加を受け入れる前例があります**。

PR では次の 3 点を書くと通りやすいはずです。

- `_FC9F5ED42C8A._tcp` は Google が固定した値で、アプリごとに任意に
  決められるものではないこと
- 対象は特定アプリではなく **NearDrop 系の実装すべて**であること
- サービスタイプの追加は**探索の許可範囲を広げるだけで、権限昇格を伴わない**こと

なお、この PR に含めるべきは `Resources/Info.plist` の 2 行だけです。
ワークフローの変更はフォーク固有の都合なので、上流には出さないでください。

---

## 5. 代替案として成立しないもの

Bonjour を避けて生の mDNS を UDP マルチキャストで自前実装する方法は
成立しません。`com.apple.developer.networking.multicast` entitlement が必要ですが、
これは Apple の個別審査が要り、無料 Apple ID では取得できません。
**LiveContainer 自身もこの entitlement を持っていません**
(`entitlements.xml` / `entitlements.catalyst.xml` / 各 `*.entitlements` を確認済み)。
