# モノシリ

今いる場所にまつわるWikipedia記事を距離で3段階（足元・町・広域）に分けて見せ、
カードにした記事を「同じ場所に戻ってきたとき」に復習として出題するiOSアプリ。

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
- `WikipediaClient.swift` — GeoSearch / TextExtracts の呼び出し、3段階への振り分け（`TierClassifier`）
- `Interest.swift` — 記事の面白さスコアと選択。駅の記事は4回に1回・1枚まで
- `LocationService.swift` — 位置取得、キャッシュ、通知、覚えた場所の領域監視、ワープ（`WarpSpot`）
- `Models.swift` — `KnowledgeCard`（SwiftData）と間隔反復（`ReviewScheduler`）
- `Notifier.swift` — ローカル通知と回数制限
- `*View.swift` — 画面（近く・復習・図鑑）
