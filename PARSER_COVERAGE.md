# メールParser 実運用精度カバレッジ

対象は `CardBills/Services/EmailBillingParser.swift`（共通）＋ `CardBills/Gmail/CardCompanyBillingParsers.swift`（会社別）＋ `CardBills/Gmail/GmailAPIClient.swift`（`HTMLTextExtractor`）。
検証は Windows 実行の挙動ポート（`scratchpad/parser_port.py`・`coverage_fixtures.py`、`re`≈ICU）と XCTest（Mac TODO）。**実メール本文は保存しない。匿名化 fixture のみ。**

## 1. 対応カード会社 × Parser カバレッジ表

| ブランド | rule id | parserKind | 専用カバレッジ fixture | 備考 |
|---|---|---|---|---|
| 楽天カード | `rakuten-card` | `.rakuten` | 11（`testRakutenMailBodyCoverage`）| |
| 三井住友カード / Vpass | `smbc-card` | `.smbc` | 11（`testSMBCMailBodyCoverage`）| |
| Amazon Mastercard | `smbc-card`（alias） | `.smbc` | smbc を流用 | 三井住友発行のため専用ルールなし |
| PayPayカード | `paypay-card` | `.payPay` | 11（`testPayPayMailBodyCoverage`）| |
| JCBカード | `jcb-card` | `.jcb` | 11（`testJCBMailBodyCoverage`）| |
| イオンカード | `aeon-card` | `.aeon` | 11（`testAeonMailBodyCoverage`）| |
| エポスカード | `epos-card` | `.epos` | 11（`testEposMailBodyCoverage`）| |
| dカード | `d-card` | `.dcard` | 11（`testDCardMailBodyCoverage`）| |
| ビューカード | `view-card` | `.standardStatement` | std 共通 11（`testStandardStatementMailBodyCoverage`）| |
| American Express | `amex-card` | `.standardStatement` | std 共通 11 | 英文テンプレートは対象外 |
| ダイナースクラブ | `diners-card` | `.standardStatement` | std 共通 11 | |
| セブンカード・プラス | `seven-card` | `.standardStatement` | std 共通 11 | |
| TS CUBICカード | `tscubic-card` | `.standardStatement` | std 共通 11 | |
| ジャックスカード | `jaccs-card` | `.standardStatement` | std 共通 11 | |
| アプラスカード | `aplus-card` | `.standardStatement` | std 共通 11 | |
| ポケット / ファミマカード | `pocket-card` | `.standardStatement` | std 共通 11 | |
| リクルートカード | `recruit-card` | `.standardStatement` | std 共通 11 | |

- **対応会社数**: 17 ブランド / 16 ルール（Amazon Mastercard は smbc-card に相乗り）。
- **専用 parserKind**: 7（rakuten / smbc / payPay / jcb / aeon / epos / dcard）。
- **共通 parserKind**: `.standardStatement` を 9 ブランドで共有。
- **fixture 総数**: 会社別 88（8 parserKind × 11）＋ 誤判定リスク横断 25 ＝ **113**。加えて `parser_port.py` の Parser 精度ケース 55。

### 観点カバレッジ（8 parserKind すべてで ✓）

| 観点 | 内容 |
|---|---|
| 請求確定 | 「ご請求金額確定のお知らせ」等、確定額＋支払日 |
| 支払予定 | 「ご請求予定金額 / お支払い予定金額」＋予定日 |
| 支払日前通知（金額あり） | 「まもなくお支払い日」＋今回額 → complete |
| 支払日前通知（金額なし） | 同上で金額欠落 → `reviewMissingAmount` |
| HTML / plain | HTML 版・plain 版の両方 |
| 件名・表記揺れ | 合計 / 確定金額 / 口座振替金額 / スラッシュ日付 / ハイフン日付 / 曜日付き |
| 全角数字・全角空白 | `４２，３５０円` / 全角スペース区切り |
| リボ・分割・利用額・ポイント混在 | headline 総額を採用し内訳・利用額・ポイントを拾わない |
| 金額欠損 / 日付欠損 / 両方欠損 | それぞれ nil（捏造しない） |

### 横断（誤判定リスク）カバレッジ — `testParserMisrecognitionRiskCoverage`（25）

部分金額の非採用（リボ払い当月／分割払い／キャッシング／ボーナス）×計8、明示総額の最優先×2、HTMLテーブル構造対応×8、年なし `11-10`×3、今回/次回併記→今回選択×3、素ラベル「請求金額: X円」の安全取得×4。
共通実装（`EmailBillingParser` ＋ `HTMLTextExtractor`）のため、代表 parserKind で検証した挙動は全会社に適用される。

## 2. 誤抽出 / 取りこぼしの安全側分類

| ケース | Parser の挙動 | 分類 | 帰結カテゴリ |
|---|---|---|---|
| 金額ラベルなし・利用/ポイント文脈が近接 | 金額 nil（fallback も除外） | **安全（取りこぼし）** | `reviewMissingAmount` |
| 日付ラベルなし・本文に日付表現なし | 支払日 nil | **安全（取りこぼし）** | `reviewMissingDate` |
| リボ / 分割主体で総請求額の明示がない | 金額 nil（意図的に採らない） | **安全（取りこぼし）** | `reviewMissingAmount` |
| 0円請求 | amount = 0 | **安全**（complete にしない） | `reviewZeroAmount` |
| 送信元の認証未確認（iCloud で AR ヘッダ欠落） | 候補化はするが自動確定させない | **安全** | `reviewUnverifiedSender` |
| `<div>` / CSS グリッドで組んだ表 | 構造解析対象外 → nil か fallback | **安全（取りこぼし）** | `reviewMissing*` |
| 和暦（令和8年）/ 英語テンプレート | 日付・金額 nil | **安全（取りこぼし）** | `reviewMissing*` |
| 1通に複数請求（合算通知） | 先頭の 1 件のみ抽出、残りは無音で取りこぼし | **概ね安全**：誤った合算額は作らないが、残りは検知されない | 取得分は `complete`／残りは候補なし |
| `1-5` 等 1桁ハイフンを月日と誤認（他に日付が皆無のメール限定） | 誤った支払日が入る | **要監視（誤抽出）**：日付が埋まるため needsReview に落ちない | `complete`（誤） |
| 素ラベル「請求金額」が FAQ 等の文脈で金額に近接 | 誤った金額を拾う可能性（`円` 必須＋近傍除外で緩和） | **要監視（誤抽出）** | `complete`（誤） |

- 大半の取りこぼしは **安全側（needsReview でユーザー確認）**。誤った値を自動保存する経路は「日付の 1桁ハイフン誤認」「素ラベルの文脈誤り」の 2 系統のみで、いずれも発生条件が限定的。
- **今後の修正方針**: 上記「要監視」は、実メールで実際に誤りが確認されたパターンだけ対象に修正する（投機的な追加対応はしない）。

## 3. needsReview へ落とす条件（確認結果）

`BillingCandidate.extractionState == .needsReview` になるのは次のいずれか（`CardBills/Mail/MailModels.swift`）:

1. `amount == nil`（金額未取得）
2. `amount <= 0`（0円を含む。`hasValidAmount` は `amount > 0`）
3. `paymentDate == nil`（支払日未取得）
4. `cardName` が空
5. `trustLevel == .limited`（送信元認証を確認できない）— 1〜4 がそろっていても `.needsReview` 固定

UI 側（`GmailImportReviewView` / `GmailImportDraft.canSave`）:

- included な draft は「カード選択済み・金額 > 0・支払日あり・（検出 or 明示確認）」で初めて保存可。
- `trustLevel == .limited` の draft は金額・支払日を**ユーザーが明示確認するまで** `canSave == false`（自動確定させない）。控えめな注記「送信元の認証情報を確認できませんでした」を表示。

Reconciler 側（`BillingCandidateReconciler`）:

- 0円確定は Bill を作らずサイクル記録のみ（前通知も抑止）。
- 金額 or 支払日が欠けた候補は、同一サイクルの確定候補／保存済み請求があれば抑止（重複防止）、無ければ needsReview 候補として残す。

## 4. DEBUG 診断（会社別の成功 / 失敗理由）

`MailCheckMetrics.finish(reconciled:)` が reconcile 後の候補を `BillingOutcomeCategory.classify` で分類し、会社ID → カテゴリ → **件数のみ** を集計（`outcomeByCompany`）。
`#if DEBUG` で `Logger(subsystem:…, category: "mail-check")` に出力:

```
<initial|incremental> outcomes rakuten-card{complete=2 reviewMissingAmount=1} jcb-card{reviewUnverifiedSender=1}
```

| カテゴリ | 意味 |
|---|---|
| `complete` | 金額(>0)・支払日・カード名がそろい追加確認なしで保存可 |
| `reviewMissingAmount` | 支払日は取得、金額 nil |
| `reviewMissingDate` | 金額は取得、支払日 nil |
| `reviewMissingBoth` | いずれも未取得 |
| `reviewZeroAmount` | 0円請求（状態として保持） |
| `reviewUnverifiedSender` | 送信元認証を確認できない（limitedTrust） |

**ログに残さないもの（テストで検証済み）**: メール本文、請求金額、支払日、件名、カード名、message ID、メールアドレス、受信日時。ログは「固定の会社ID・カテゴリ名・整数件数」のみ。

## 5. 想定成功率（＝ `complete` 率）を下げる主な要因

1. **非テーブルの表組み HTML**（`<div>` / CSS グリッドで整形）— ラベルと値を構造で結べず nil / fallback。
2. **配信ドメインの変更**（カード会社の ESP 移行等）— allowlist 外となり候補化されない（セキュリティ側の取りこぼし。安全だが取得率は下がる）。
3. **iCloud の認証ヘッダ欠落** — `limitedTrust` → `reviewUnverifiedSender` 固定で自動確定率が下がる（安全側）。
4. **未知の見出し表記** — 既知ラベルに一致せず fallback 依存。近傍に「利用 / ポイント / リボ」等があると金額 nil。
5. **リボ・分割主体の明細**（総請求額ラベルがない）— 意図的に金額 nil。
6. **1通に複数請求** — 先頭 1 件のみ取得、残りは無音で取りこぼし。
7. **支払日がラベル外 / 相対表現**（「締め日」「翌々月10日」等）— 支払日 nil。
