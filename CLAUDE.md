# モノシリ

Wikipediaのネタを「〇〇〇に入るのは？」という問いかけカードにして1枚ずつめくらせ、
カードにした記事を「同じ場所に戻ってきたとき」に復習として出題するiOSアプリ。
今いる場所にまつわる記事も、距離で3段階（足元・町・広域）に分けて見せる。

## 開発環境の前提
- 持ち主は主に **iPad の Swift Playground** で実行する。Xcode・シミュレータ・CLI でのビルドは使えない前提で書くこと
- アプリ本体は `MonoSiri.swiftpm`（App Playground 形式）。Mac では同じものを Xcode で開ける
- 変更はこのフォルダ内の Swift ファイルだけで完結させる

## 守ること
- **public リポジトリ**。APIキー・トークン・メールアドレスなどの個人情報をコードにもコミットにも入れない。
  コミットの作者は `ys7i <69115711+ys7i@users.noreply.github.com>` を使う
- Swift ファイルは `MonoSiri.swiftpm/` の**直下**に置く（サブフォルダを作らない）
- 画像・JSON などのリソースファイルは追加しない（必要ならコード内に埋め込む）
- `Package.swift` は Swift Playground が自動生成・上書きするファイル。書式を崩さない。
  権限（capabilities）を増やす必要があるときは、変更内容をコミットメッセージにも書く
- 外部ライブラリ（SwiftPM 依存）は追加しない
- iOS 17 以上。SwiftUI + SwiftData + CoreLocation + UserNotifications
- UI の文言・コメントは日本語
- ビルドで確認できないので、コミット前に型・import・引数ラベルを読み直す。
  自信のない API は使わず、確実に存在するものを使う

## 構成
- `FeedService.swift` / `FeedView.swift` — 「めくる」画面。新しい記事（`Template:新しい記事`）・今日は何の日（日付記事の「できごと」）・おすすめ・近くの記事を、答えを伏せた問いにして交互に並べる。答えを見たものは `SeenStore` に記録して再出題しない
- `WikiText.swift` — ウィキテキストの整形、リンク抽出、答えの伏せ字化
- `WikipediaClient.swift` — 記事の取得。足元は GeoSearch、町・広域は全文検索の `nearcoord:` で「由来・伝説・合戦」などを含む記事を探し、距離で3段階に分ける。おすすめは秀逸な記事・良質な記事からランダム
- `Interest.swift` — 記事の面白さスコアと選択。建物・学校などは大きく減点、山・川は軽く減点。駅の記事は4回に1回・1枚まで
- `LocationService.swift` — 位置取得、キャッシュ、通知、覚えた場所の領域監視、ワープ（`WarpSpot`）
- `Models.swift` — `KnowledgeCard`（SwiftData）と間隔反復（`ReviewScheduler`）
- `Notifier.swift` — ローカル通知と回数制限
- `*View.swift` — 画面（近く・復習・図鑑）
