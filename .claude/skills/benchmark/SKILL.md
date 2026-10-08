---
name: benchmark
description: このスキルを使用して、パフォーマンスベースラインを測定し、PR前後の回帰を検出し、スタック代替案を比較します。
origin: ECC
---

# ベンチマーク — パフォーマンスベースラインと回帰検出

## 使用時期

- PR前後にパフォーマンスへの影響を測定
- プロジェクトのパフォーマンスベースラインを設定
- ユーザーが「遅く感じる」と報告したとき
- ローンチ前 — パフォーマンスターゲットを満たしていることを確認
- スタックを代替案と比較

## 動作方法

### モード1：Swift/SwiftUIアプリパフォーマンス

XCTestの`measure { }`ブロックでアプリ層の処理を計測：

```
1. XCTestCase内でmeasure { } に計測対象のコードを置く
2. デフォルトで複数回自動実行し、平均・標準偏差を算出
3. 必要なメトリクスをXCTMetricとして指定：
   - XCTClockMetric — 壁時計時間
   - XCTMemoryMetric — メモリ使用量
   - XCTCPUMetric — CPU使用率
4. Xcodeのベースライン機能で基準値を保存し、許容偏差を超えたら失敗させる
```

時間・メモリがどこで消費されているかはInstrumentsでプロファイリング：
- Time Profiler — CPUホットスポットの特定
- Core Animation FPS — スクロール/再生中のフレームレート計測（SwiftUIの再レンダリングオーバーヘッド診断に有効）
- Allocations — メモリ割り当てとリークの追跡

### モード2：オーディオ / UniFFI ホットパスパフォーマンス

Spotify/librespot系クライアントで実際にベンチマークする価値があるのはこの領域（Veyaではまだ計測基盤がないが、優先的に整備する価値がある）：

```
1. オーディオバッファのアンダーラン率
2. デコードレイテンシ（librespotのデコードパイプライン）
3. 再生中・スクロール中のUIフレームレート
4. UniFFI越しのSwift↔Rustホットパス呼び出しオーバーヘッド（p50/p95/p99レイテンシ）
```

### モード3：ビルドパフォーマンス

開発フィードバックループを測定：

```
1. Xcodeコールドビルド時間（xcodebuild clean build）
2. Xcodeインクリメンタルビルド時間
3. cargo buildのコールド/インクリメンタル時間（core/spotcore）
4. テストスイート期間（XCTest + cargo test）
5. SwiftLint / cargo clippy実行時間
6. SwiftUIプレビューのリフレッシュ時間
```

### モード4：前後の比較

変更前後に実行して影響を測定：

```
/benchmark baseline    # 現在のメトリクスを保存
# ... 変更を加える ...
/benchmark compare     # ベースラインと比較
```

Rustコア（core/spotcore）側は`cargo bench`と`criterion`クレートを使う。criterionは複数回サンプリングして統計的信頼区間を計算し、変更が「ノイズ」か「実際の回帰」かを自動判定する — これはこのスキルの核心（手動の目視比較をしない）をそのまま体現する機能なので、独自の閾値判定ロジックを書く前にまずcriterionに任せる：

```
cargo bench -- --save-baseline before
# ... 変更を加える ...
cargo bench -- --baseline before
```

Swift側はXCTestのベースライン機能（上記モード1）で同様の前後比較を行う。

出力：
```
| Metric | Before | After | Delta | Verdict |
|--------|--------|-------|-------|---------|
| UniFFI call (p95) | 42µs | 45µs | +3µs | WARNING: WARN |
| Decode latency (p50) | 1.8ms | 1.7ms | -0.1ms | ✓ BETTER |
| Build (cargo) | 9s | 11s | +2s | WARNING: WARN |
```

## 出力

`.ecc/benchmarks/`にJSONとしてベースラインを保存。Gitで追跡されるため、チームはベースラインを共有します。

## 統合

- CI：すべてのPRで`/benchmark compare`を実行
- `/perf-issue`とペアリングして特定の遅延箇所を深掘り
- リリース前チェックリストとペアリングして出荷前の最終確認
