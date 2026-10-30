---
paths:
  - "Packages/SurimonoKit/Tests/**"
  - "AppTests/**"
---

# テストの細則

- Swift Testing（`import Testing`、`@Test`、`#expect`、`#require`）を使う。XCTest で新しいテストを書かない。
- テスト名は日本語で振る舞いを書く: `@Test("A4 用紙の冊子は A5 の論理ページになる")`。
- 1 つのテストで 1 つの振る舞いを確かめる。期待値はテストに直接書き、実装の計算を再利用しない。
- fixture は個人情報や実データを入れず、できるだけテスト内で生成する。ファイルとして置く場合:
  - SurimonoKit: `Packages/SurimonoKit/Tests/<ターゲット名>/Fixtures/` に置き、Package.swift の該当 testTarget に `resources: [.copy("Fixtures")]` などを登録して `Bundle.module` から読む。
  - AppTests（Xcode のホスト付きテスト。`Bundle.module` は無い）: `AppTests/` 配下に置くと synchronized folder によりテストバンドルに入るので、テストファイル内のクラス（例 `private final class BundleToken {}`）から `Bundle(for: BundleToken.self)` で読む。
- 面付けや用紙寸法など仕様として固定した値は、AGENTS.md と同じ例でテストする。
- WebKit を使うテストは最小限にし、`.timeLimit(.minutes(1))` を付ける。Kit の Rendering のテストは、`make test-kit`（`SWIFT_TEST_FLAGS` を指定しないとき）では直列に走る。`SWIFT_TEST_FLAGS` で個別に走らせるときは、必要に応じて `--no-parallel` を付ける。直列で 1 件が 1 分を超えるような重いテストは作らない。
