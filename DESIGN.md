# Mail Ledger デザインガイド

複数クレカの「今後の請求」を1秒で把握するための iOS 17+ SwiftUI アプリ。
家計簿ではなく「いつ・どのカードで・いくら引き落とされるか」の確認に特化する。

このドキュメントは UI/UX の判断基準を定める。実装（SwiftUI コード）はこのガイドに従って別途更新する。

---

## 1. 目的とスコープ

- コア価値：複数カードの請求予定をまとめ、Gmail / iCloud Mail から請求額・支払日を自動取得する。メール本文は iPhone 内だけで解析する。
- 対象画面：ホーム / 履歴（年月セレクター）/ メール連携 / 自動取得候補の確認 / カード管理 / 設定 / Mail Ledger Pro Paywall / 空状態 / 成功・エラー・要確認 / ウィジェット（将来）。
- トーン：Apple 純正アプリに近い余白・情報階層。金融アプリとしての安心感は出すが堅苦しくしすぎず、少しだけ可愛げを残す。日本語 UI・片手操作前提。ライト / ダーク / Dynamic Type / Increase Contrast / VoiceOver 対応。

---

## 2. リファレンスから抽出した共通原則

styles.refero.design の fintech / banking 系デザインシステム（Mercury、Ramp、Public）と、Apple 純正アプリ（ウォレット、株価、設定、App Store）から、特定スタイルを丸コピーせず共通項だけを抽出した。

| 出典 | 共通して言えること |
| --- | --- |
| Mercury（cobalt 1色 / flat elevation / 余白で階層 / 見出しは太くしすぎない） | アクセント色は「主要アクション1つ」に限定。分離はコントラストと余白で作り、影は使わない。 |
| Ramp（monochrome + neon 1色 / 太さでなくサイズと字間で階層 / hairline border） | 階層は色や太さより「サイズ・余白・区切り線」。カードは影ではなく 1px 相当の境界。 |
| Public / fintech 一般（clear・credible・calm / 数値に意図的な階層 / personality は装飾でなくコピーと挙動） | 金額など数値要素に最優先の視覚的重み。個性は文章とマイクロインタラクションで出す。 |
| Apple 純正（systemGroupedBackground、Section 見出し、44pt 行、下部に主要操作） | ネイティブのリズムに合わせると学習コストが下がり、安心感につながる。 |

**結論：** Mail Ledgerは「アクセント1色を金額と主要操作だけに使う。階層は余白と文字サイズで作る。影・グラデ・ガラスは使わない。個性はコピーと日付チップ程度の小物で出す」方向に寄せる。

---

## 3. デザイン原則

- **A. 金額ファースト** — 金額は各文脈で最大かつ最も強い数値要素。`monospacedDigit` を必須にし、`¥` 記号はひとまわり小さく `.secondary`。カード名・日付より視覚的に前へ出す。
- **B. 3語で読める** — 「いつ・どのカード・いくら」を `日付チップ / カード名 / 金額` の横一列に固定。ホーム・履歴・確認画面で同じ `BillRow` を使う。
- **C. アクセントは1色、お金と操作だけ** — アクセント色を使ってよいのは「合計金額」「主要 CTA」「連携済みバッジ」。見出し・区切り線・装飾アイコンは neutral（`.label` / `.secondary`）。`softAccent` は日付チップなど機能を持つ要素のみ。
- **D. 階層は余白と文字サイズ** — 色面や影で階層を作らない。ホームの3階層は「見出しの大きさ」「カード内余白」「区切り線の有無」で差をつける。
- **E. フラット** — hairline セパレータ、角丸は2〜3段階のみ、影・グラデーション・glassmorphism は不使用。ホーム上部の全面塗り（白文字 on 濃アクセント）は廃止し、淡いティント面＋アクセント金額に置き換える。
- **F. iOS 純正のリズム** — `systemGroupedBackground` / `secondarySystemGroupedBackground`、Section 見出しは 13pt `.secondary`、行の最小高さ 44pt、主要 CTA は親指の届く下部に置く。
- **G. 状態は3種を明快に** — 成功（success green・チェック）/ 要確認（warmWarning・`exclamationmark.circle.fill`）/ エラー（赤・ブロッキングは Alert）。要確認は色だけでなくラベル文字とアイコンでも示す。
- **H. 安心は自然に、断定しない** — 「メールの解析は iPhone の中だけ」「メール本文はMail Ledgerのデータとして保存しません」「開発者のサーバー・広告 SDK・外部 AI へ送信しません」等の事実ベースの文で伝える。「完全に安全」「絶対に漏れない」等の断定は禁止。連携画面とホームに1行だけ添える。
- **I. アクセシビリティは既定** — 金額の固定 `size:` をやめ Dynamic Type 対応の text style ＋ `monospacedDigit`（`minimumScaleFactor` は保険）。VoiceOver の読み順＝視覚順。Increase Contrast でセパレータと `.secondary` を濃くする。色だけで情報を伝えない。
- **J. 少しの可愛げ** — 角丸は `.continuous`、日付チップ、SF Symbols を細めの線幅で統一、マイクロコピーは柔らかい語尾。ここ以外で装飾を足さない。

---

## 4. デザイントークン

`AppTheme` / `AppSupport.swift` に集約する。マジックナンバーを減らす。

### 4.1 カラー

| トークン | 用途 |
| --- | --- |
| `accent`（テーマ可変） | 合計金額、主要 CTA、連携済みバッジ、選択中タブ。**それ以外に使わない。** |
| `softAccent`（テーマ可変） | 日付チップ、Pro マーク背景、安心メッセージのコールアウト背景。 |
| `summaryBackground` | 廃止方向。ホーム hero の全面塗りをやめるため、当面は使用停止。将来ウィジェットの濃色面が必要になった場合のみ再利用を検討。 |
| `AppTheme.groupedBackground` = `systemGroupedBackground` | 画面地。 |
| `AppTheme.surface` = `secondarySystemGroupedBackground` | カード・行の面。 |
| `Color(uiColor: .separator)` | hairline 区切り。新規トークン `AppTheme.hairline` として公開。 |
| `AppTheme.warmWarning` | 要確認、支払い間近（3日以内）。 |
| `AppTheme.success` | 自動取得成功、購入完了。 |
| `.secondary` / `.tertiary` | 補助テキスト、chevron。見出しもここ（アクセント禁止）。 |

- ダーク：既存の各 colorset のダーク値を維持。追加面は作らず、`surface` と `groupedBackground` のコントラストだけで分離する。
- Increase Contrast：`@Environment(\.colorSchemeContrast)` が `.increased` のとき、hairline を `.separator` → `.label.opacity(0.35)` 相当へ、`.secondary` テキストを一段濃くする。

### 4.2 タイポグラフィ

すべて Dynamic Type 対応の system font。固定 `size:` は金額 hero のみ（かつ `.minimumScaleFactor(0.7)` を併用）。

| 役割 | スタイル |
| --- | --- |
| 金額 / hero（今月の残り、Paywall 価格） | `.system(.largeTitle, design: .rounded).weight(.bold)` ＋ `monospacedDigit()` |
| 金額 / 行・次の引き落とし | `.title3` または `.body` の `weight(.semibold).monospacedDigit()`（カード名より必ず一段強く） |
| 画面内セクション見出し（ホームの3階層） | `.headline`（色は `.primary`、アクセント不可） |
| リスト Section 見出し（履歴・設定） | `.footnote` 相当・`.secondary`・必要に応じて大文字化しない（日本語のため） |
| カード名・主要ラベル | `.body.weight(.semibold)` |
| 補助（日数、件数、受信日、footer） | `.footnote` / `.caption` の `.secondary` |
| 日付チップ | 月 `.caption2.weight(.semibold).secondary` / 日 `.title3.weight(.bold).monospacedDigit()` |

### 4.3 余白（8pt グリッド寄り）

- スケール：`4 / 8 / 12 / 16 / 20 / 24 / 32`。
- 画面水平パディング：`20`。
- カード内パディング：`16`（コンパクト）〜`20`（hero）。
- セクション間：`24`（ホーム）。行内アイテム間：`12`〜`14`。
- 行の最小高さ：`44`。日付チップ：`48 × 50`。

### 4.4 角丸（`.continuous`）

| トークン | 値 | 用途 |
| --- | --- | --- |
| `panelCornerRadius` | `20` | ホーム hero、大きめカード。 |
| `cardCornerRadius`（新規） | `16` | 標準カード、リストコンテナ、比較表。 |
| `compactCornerRadius` | `12` | 日付チップ、アイコン箱、コールアウト。 |
| `ctaCornerRadius`（新規） | `14` | 主要ボタン。 |

現状の `24 / 20 / 13` から `20 / 16 / 14 / 12` へ整理。

### 4.5 区切り・影

- 区切りは常に hairline（`AppTheme.hairline`）。カードの縁取りは付けない（面色で分離）。
- 影・グラデーション・`.ultraThinMaterial` の装飾利用は禁止。ナビゲーションバー / タブバー / 下部固定バーのシステム標準ブラーのみ許可。

### 4.6 状態トークン

| 状態 | 色 | アイコン | 文言例 |
| --- | --- | --- | --- |
| 自動取得 OK / 成功 | `success` | `checkmark.circle.fill` | 「自動取得」「読取済み」「購入しました」 |
| 要確認 | `warmWarning` | `exclamationmark.circle.fill` | 「要確認」「金額を確認してください」 |
| 支払い間近（≤3日） | `warmWarning` | なし（文字色のみ） | 「今日」「明日」「あと3日」 |
| エラー（ブロッキング） | 赤（システム） | Alert | 「保存できませんでした」等、原因を短く |
| 中立 / 経過 | `.secondary` | — | 「支払日経過」「新しい請求はありません」 |

---

## 5. 共通コンポーネント

1つの役割につき1つの見た目に統一する。

- **BillRow** — `日付チップ / (カード名 + 補助行) / 金額`。金額はカード名より強い。タップで編集。ホーム「その後の請求」、履歴、確認画面で共通。
- **DateChip** — `softAccent` 面・角丸 12・`月 / 日`。VoiceOver では1つの読み上げにまとめる。
- **Card / Panel** — `surface` 面、角丸 16（hero は 20）、内側 16〜20、影なし。縦積みの行は hairline で区切る。
- **SectionHeading** — ホーム3階層用。`.headline` `.primary`、下 `12`。
- **StatusChip** — 4.6 の状態トークンに従う小さな `Label`。色＋アイコン＋文字の3点セット。
- **EmptyState** — `ContentUnavailableView` ベースの薄いラッパー（`icon / title / message / actionTitle?`）。ホームの階層内の「まだない」表示も同じ語彙で（現在のインラインのミニカードは廃止）。
- **PrimaryButton** — `borderedProminent` 相当、`controlSize(.large)`、角丸 14、最小高さ 50、幅いっぱい。
- **BottomActionBar** — Paywall 等の下部固定領域。hairline 上境界、safe area 尊重、本文はこの下をスクロール。
- **PrivacyCallout** — `softAccent` 面・角丸 12・`lock.shield` 系アイコン＋短い事実文。断定表現を含めない。

---

## 6. 画面別ガイドライン

### 6.1 ホーム

3階層を「サイズ・ティント・密度」で明確に分ける。

1. **今月の残り請求（hero）**
   - `softAccent` の淡いティント面（白文字 on 濃アクセントの全面塗りは廃止）。
   - 合計金額を `accent` 色・largeTitle rounded・monospacedDigit で最大表示。
   - 上に「今月の残り請求 ・ N件」、下に「今日以降、月末までの合計」。
   - 0件時は EmptyState 語彙で「今月の支払い予定はありません」。
2. **次の引き落とし（1件フォーカス）**
   - `surface` カード。`日付（M月D日・大きめ） / カード名 / 金額 / カウントダウン`。
   - カウントダウンは ≤3日 のときだけ `warmWarning`。それ以外は `.secondary`（現在は常時警告色 → 修正）。
   - 予定なしのときはこのカード自体を出さない。
3. **その後の請求（リスト）**
   - `surface` カードに `BillRow` を hairline 区切りで縦積み。
   - `.headline` 見出し「その後の請求」。
   - 0件時は EmptyState（カード未登録なら「カードを登録すると請求を追加できます」、あれば「右上の＋から追加できます」）。

- メール連携中は「最終確認 hh:mm / 新しい請求はありません」等のステータスを hero と次の引き落としの間に、独立した行ではなく小さなカードとして置く（現在は浮いた HStack）。
- ナビゲーションバー：大タイトル「Mail Ledger」、右上 `＋`（手入力 / メールから読み取る）。
- 無料版のバナーは従来どおり `safeAreaInset(.bottom)`。バナー取得失敗時に空白を残さない。

### 6.2 履歴（年月セレクター）

現状は全月を1つの List に流しているだけ。仕様に合わせて「選択中の1か月」にフォーカスする。

- **上部バー**：`‹    2026年9月    ›        ¥68,420`
  - 左右 chevron：前月 / 翌月へ即移動。タップ領域 44pt。データのある最古月〜（現在月＋数か月）でクランプし、範囲端では chevron を dim。
  - 中央の年月：タップで年月 Picker（ホイールの `year` + `month`、`.presentationDetents([.medium])`）。年は monospacedDigit。
  - 右：その月の合計。`accent` 色・`.title3.weight(.semibold).monospacedDigit()`・右寄せ。
- **明細**：選択月の請求を日付降順で `BillRow` 表示（`surface` カード＋hairline）。必要なら日ごとの小見出し。
- **空の月**：EmptyState「この月の請求はありません」＋前後どちらへ動かせるかが分かる状態。
- 明細エリアの左右スワイプで前月・翌月（任意、chevron と等価）。
- 画面下部に「合計 N件 / ¥…」のフッター（任意）。

### 6.3 メール連携（Gmail / iCloud）

- **サービス選択**：`confirmationDialog` で Gmail / iCloud Mail。「請求メールを受信しているサービスを選んでください」。
- **説明（disclosure）画面**：
  - アイコン → 一言の価値（「Gmail を一度連携。アプリを開くだけで請求を自動チェック」）→ 事実の本文。
  - 「Mail Ledgerが行うこと」（登録カードの請求メールだけを検索 / 端末内で解析）と「行わないこと」（本文と請求情報を開発者サーバー・広告 SDK・外部 AI へ送信しない / 送信・削除・既読化はしない）を2つの短いリストに分ける。
  - `gmail.readonly` だけを要求する旨を1行。
  - CTA は下部固定「Google で続ける」。キャンセルで説明画面に留まる。
- **iCloud 接続画面**：現状の番号付き 1→2→3（メールアドレス / アプリ用パスワード発行手順 / 入力）を維持。「Apple Account の通常のパスワードは入力しないでください」を warmWarning で目立たせる。imap.mail.me.com:993 / 受信専用 / 送信機能なしを footer に。
- **設定内のステータス**：`メール` セクションの先頭に状態行（`未連携` / `N アカウント連携中` / `最終 hh:mm 確認`）、各アカウント行（provider ラベル＋アドレス＋解除ボタン）、「メールから請求を更新」、「メールアカウントを追加」。カードのリズムに合わせる。
- 連携解除の確認文はアカウントごとに具体的に（Google 許可の取り消し / Keychain 削除 / 保存済み請求は残る）。

### 6.4 自動取得候補の確認

- リード文「メール本文はすでに破棄されています。抽出結果を確認・修正してから保存してください。」を残す。
- **候補カード**（1候補 = 1カード）：
  - ヘッダー：`カード会社 provider ・ 受信日`（小さく `.secondary`）。
  - 状態チップ：`自動取得`（success）/ `一部確認が必要`（warmWarning）を大きめに。
  - 本体：`カード（Picker）` / `請求額（¥ を小さく、数字を大きく）` / `支払日（DatePicker、未検出なら「支払日を選択」）`。
  - 金額と日付の検出状況を `金額：読取済み / 日付：要確認` の StatusChip で明示。
  - 「この請求を保存」トグル。オフのカードは入力欄を dim。
- 保存はナビゲーションバー右に固定。1件でも要確認が残ると disabled。
- 既存請求の更新（後から届く確定通知）は「後から届いた確定通知として既存の請求を更新します」と明示。

### 6.5 カード管理

- **空状態**：`ContentUnavailableView`「カードはまだありません」＋「カード名と支払日だけを登録します。カード番号は必要ありません。」＋「カードを追加」。
- **カード行**：先頭にカード識別のためのアバター（カード名の頭1文字を `softAccent` 円に。色を増やさず、必要なら固定4〜6色のニュートラル寄りパレットを名前ハッシュで割当）→ `カード名 / 毎月N日` → `件数`（あれば）→ chevron。
  - 現状は全カードが同じ `creditcard.fill` ＋ `accent` で見分けづらい。アイコンではなく識別子で差をつける。
- 可能なら各行に「次回 M月D日」を薄く添える（一覧で次の支払いが分かる）。
- スワイプ：削除（destructive）/ 編集。削除確認で「請求履歴はカード名を残して保持される」旨。
- エディタ：カード名 / 支払日トグル＋日 Picker / 「入力しない情報」リスト（カード番号・有効期限・CVV・ログイン情報）。

### 6.6 設定

- セクション順：`Mail Ledger Pro` → `メール連携` → `通知`（将来）→ `テーマ` → `プライバシー` → `データ` → `Mail Ledgerについて`。
- **Pro**：未購入は「Mail Ledger Pro にアップグレード」（`sparkles`）、購入済みは「利用中」（`checkmark.seal.fill`・success）。「購入方式：買い切り」。
- **テーマ**：Pro のみ Picker（プリセット名＋色丸）。無料は「Blue」固定表示＋「テーマカラーの変更はMail Ledger Pro で利用できます」。
- **プライバシー**：短い事実行2つ（端末内で解析 / カード番号・CVV・ログイン情報は取得しない）＋「Mail Ledgerのプライバシーポリシー」への遷移。断定表現を入れない。
- **データ**：「デモデータを追加」のアイコンを Pro の `sparkles` と衝突させない（`wand.and.stars` 等へ）。「すべてのデータを削除」は destructive、削除範囲を明記。
- **Mail Ledgerについて**：通信先 / アカウント不要 / 外部 SDK / Pro 状態 / 対応 OS を `LabeledContent` で。
- 広告のプライバシー設定は UMP が要求する地域のみ表示（現状維持）。

### 6.7 Mail Ledger Pro Paywall

`preview/PAYWALL_SPEC.md` を正とする。現状の実装（アイコン＋4行＋ボタン）は仕様未達なので、次の構成へ作り替える。

- **Hero**：Pro マーク（`softAccent` 角丸16 箱＋`sparkles`）→ 見出し固定「**一度買えば、ずっと快適。月額料金なし。**」→ 価格を画面最大の要素として `accent`・rounded・monospacedDigit（`Product.displayPrice`、コードに固定しない）→ 補足「月額・年額料金なし」。
- **Pro 機能一覧**：hairline 区切りの行（アイコン＋タイトル＋補足）。**同じ公開版で実際に使える機能だけ**を出す（SPEC §5）。現時点で出してよいのは `広告なし` / `メールを合計2アカウント連携` / `6テーマ`。`ホーム画面ウィジェット` / `CSV エクスポート` / `通知カスタマイズ` は実装・提供が済むまで Paywall に載せない。
- **Free / Pro 比較表**：角丸14、hairline グリッド、Pro 列だけ極薄ティント（accent 5%）。行は SPEC の表に従う。
- **安心の注記**：比較表直後に `softAccent` コールアウトで「安心に関わる機能は無料のまま。基本の請求管理、メール自動取込、端末内での解析・保存は Free でも利用できます。」
- **下部固定購入バー**：hairline 上境界・safe area 尊重。「一度きりの買い切りです。追加料金はありません。」（小）＋ 大 CTA「{price} でMail Ledger Pro を購入」＋ テキストボタン「購入を復元」。本文だけスクロール。
- **状態**：Loading（価格・CTA をスケルトン）/ Ready / Purchasing（CTA 内スピナー・二重操作防止）/ Pending（「購入は承認待ちです」）/ Success（→ 6.9 の購入完了へ）/ 復元対象なし（「復元できるMail Ledger Pro 購入は見つかりませんでした」）/ キャンセル（Alert を出さない）。
- **禁止**：偽の割引・取り消し線価格・カウントダウン・期間限定・人気順位・偽レビュー・強いセール演出。
- コンポーネント分割：`ProPaywallHero` / `ProBenefitList` / `ProComparisonTable` / `ProFreeSafetyNote` / `ProPurchaseBar`。`ProStore` / entitlement 判定は変更しない。

### 6.8 空状態（Empty State）

- すべて `ContentUnavailableView` ベースの共通 `EmptyState` に統一（ホームの階層内も含む）。
- 構成：SF Symbol（`.secondary`、装飾しすぎない）→ 1行タイトル → 1行の次アクション案内 →（あれば）CTA 1つ。
- コピー例：
  - 履歴：「履歴はまだありません」/「登録した請求が月ごとに表示されます。」
  - カード：「カードはまだありません」/「カード名と支払日だけを登録します。」
  - 今月：「今月の支払い予定はありません」
  - その後：「その後の請求はありません」
  - メール未連携：「メールはまだ連携していません」/「連携すると請求額と支払日を自動で取り込みます。」
- 語尾は柔らかく。感嘆符やイラストの追加はしない。

### 6.9 成功・エラー・要確認

- **成功**：
  - 保存系（請求・カード）：シートを閉じて一覧へ戻るだけ（余計な確認 Alert を出さない）。必要なら一覧上部に一時的なインラインバー。
  - 購入完了：専用の小画面。`checkmark.seal.fill`（success）＋「Mail Ledger Pro を利用中に」＋変わること3点（広告が消えます / メールを2アカウント / テーマを選べます）＋「閉じる」。紙吹雪などの過剰演出はしない。
- **要確認**：`warmWarning` ＋ `exclamationmark.circle.fill` ＋ 文字ラベル。色だけに頼らない。確認画面・ホームで表現を統一。
- **エラー**：
  - 操作を止める失敗（保存不可・連携不可・購入失敗）は Alert。タイトルは短く、本文で原因と次の一手。
  - 回復可能・軽微（本文の解析に失敗、価格取得に失敗）はインラインの `.footnote` warmWarning ＋ 再試行導線。
- どの状態も VoiceOver で状況が読み上げられること。

### 6.10 ウィジェット（将来 / Pro）

- Small：`次の引き落とし` = 日付＋カード名＋金額（金額のみ accent）。
- Medium：`今月の残り合計` ＋ 次の3件リスト。
- 見た目はアプリ準拠：`systemBackground`、金額以外に色を使わない、グラデ・影なし。
- Paywall に載せるのは実際に提供を開始してから（SPEC §5）。

---

## 7. アクセシビリティ

- **Dynamic Type**：金額 hero 以外は固定 `size:` を使わない。hero も text style ベース＋`minimumScaleFactor(0.7)`＋`lineLimit(1)`。最大サイズで hero / 機能一覧 / 比較表が縦に自然拡張すること。
- **VoiceOver**：読み順＝視覚順。`BillRow` は「9月27日、楽天カード、38,240円、あと5日」のように1要素へ結合。金額は通貨として自然に読み上がる Label。比較表は行名・Free・Pro の関係が分かる Label。
- **Increase Contrast**：hairline と `.secondary` を一段濃く。要確認/成功は色に加えてアイコンと語で判別できる（既に準拠方針）。
- **タップ領域**：CTA・chevron・年月セレクターの左右矢印は 44pt 以上。
- **Reduce Motion**：画面遷移・シート表示のカスタムアニメーションを無効化。
- **色のみで伝えない**：Free/Pro 差、要確認、支払い間近はいずれも文字とアイコンを伴う。

---

## 8. 避けること

- AI 生成 UI にありがちな大量のカードの羅列。1画面の主役は1つ。
- 装飾目的のグラデーション、glassmorphism、強い影、光彩。
- アクセント色の多用（見出し・区切り・装飾アイコンへの使用）。色数を増やすこと。
- 小さすぎる文字（本文 13pt 未満を情報伝達に使わない）。
- 装飾だけのアイコン。意味のない挿絵。
- Paywall の偽割引・カウントダウン・期間限定・取り消し線価格・偽レビュー・人気順位。
- プライバシー文の断定（「完全に安全」「絶対に漏れない」）。
- 特定 Refero デザイン（Mercury 等）の配色・書体・レイアウトの丸コピー。

---

## 9. 実装優先順位

> 実装状況（2026-09-02）：P0〜P2 を反映済み。トークン整備、共通コンポーネント（`BillRow` / `DateChip` / `EmptyStateView` / `StatusChip` / `InlineNoticeRow` / `PrimaryButtonStyle` / `PrivacyCallout` / `CardAvatar`）、ホーム3階層、履歴の年月セレクター、Paywall 作り替え（出荷済み機能のみ）、購入完了画面、メール連携の説明画面、カードのモノグラム＋次回支払日、設定のセクション順・アイコン整理を実装。ブラウザプレビュー（`preview/`）も同じ方向へ更新。P3（アクセシビリティ総点検・ウィジェット）は未着手。

| 優先 | 対象 | 内容 | 目安 |
| --- | --- | --- | --- |
| P0 | トークン整備（`AppSupport.swift` / `AppTheme`） | 角丸を `20/16/14/12` に整理、`AppTheme.hairline`・金額用 text style・spacing 定数を追加。挙動は変えず土台だけ。 | 小 |
| P0 | ホーム3階層 | hero を淡ティント＋アクセント金額に変更、次の引き落としのカウントダウン警告色を ≤3日 限定に、メール状態を小カード化、階層のサイズ/余白差を付ける。 | 中 |
| P0 | 履歴の年月セレクター | `‹ 2026年9月 › ¥合計` バー＋前月/翌月＋年月 Picker＋選択月フォーカス表示へ作り替え。 | 大 |
| P1 | Paywall 作り替え | `PAYWALL_SPEC.md` 準拠（Hero＋価格 hero＋機能一覧＝出荷済みのみ＋比較表＋安心注記＋下部固定バー＋状態分岐）。コンポーネント分割。 | 大 |
| P1 | 共通コンポーネント抽出 | `BillRow` / `DateChip` / `EmptyState` / `StatusChip` / `PrimaryButton` / `PrivacyCallout` を1定義に統一。ホームのインライン空状態を `EmptyState` へ。 | 中 |
| P1 | 確認画面（自動取得候補） | 候補カード化、金額前面、状態チップ統一、保存不可条件の可視化。 | 中 |
| P2 | メール連携の説明画面 | 「行うこと / 行わないこと」の2リスト構成、CTA 下部固定、設定内ステータス行の整理。 | 中 |
| P2 | カード管理 | 頭文字アバターで識別、次回支払日の表示（任意）。 | 小 |
| P2 | 設定 | セクション順の調整、デモデータのアイコン衝突解消、プライバシー行の簡潔化。 | 小 |
| P2 | 成功/エラー/要確認 | 購入完了の専用小画面、保存系の余計な Alert 削減、要確認アイコンの統一、回復可能エラーのインライン化。 | 中 |
| P3 | アクセシビリティ総点検 | Dynamic Type 最大・VoiceOver 読み順・Increase Contrast・Reduce Motion をライト/ダークで確認。 | 中 |
| P3 | ウィジェット | Small/Medium のデザイン確定は提供開始時に合わせて。 | 大 |
