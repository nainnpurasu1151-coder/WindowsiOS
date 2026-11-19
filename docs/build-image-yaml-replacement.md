# build-image.yml 差し替え手順（再開可能化）

対象ファイル：`.github/workflows/build-image.yml`（ファイル全体を差し替える）

## 何が変わるか

- 旧 `prepare` ジョブを `fetch-esd` と `installer` の2ジョブに分割。
  - `fetch-esd`：UUP取得→ISO変換→合成ESD（約40分）。成果物は `windows-esd` のみ。
    ここが成功すれば、後段が失敗しても ESD は成果物として残る。
  - `installer`：ESDを取り込んで installer image を作る。
- 入力 `esd_run_id` を追加。過去の run の `windows-esd` 成果物を再利用できる
  （`helpers_run_id` と同じ仕組み。再利用時は `reuse-esd` ジョブが取り込む）。

## 差し替え手順（GitHub Web）

1. リポジトリの **Code** タブ → `.github` → `workflows` → **build-image.yml** を開く
2. 右上の **鉛筆マーク（Edit）**
3. 中身を **全選択して削除** し、完成品ファイルの全文を貼り付ける
4. **「Commit changes...」→「Commit changes」** で確定
5. Actions タブで **Build Windows 11 machine image** がエラーなく表示されることを確認

## Run のしかた

- **初回**：`esd_run_id` は **空欄** のまま Run（通常通り fetch から実行）。
  `fetch-esd` が成功したら、その run の ID（run ページの URL 末尾の数字）を控えておく。
- **続きから再開したい時**：控えた run ID を `esd_run_id` に入れて Run。
  fetch（約40分）が丸ごとスキップされ、`installer` から再開される。
- 注意：run #6 以前の run には `windows-esd` 成果物は存在しない
  （旧構成では ESD が prepare ジョブ内部でしか作られなかった）ため、再利用はできない。
  成果物の保持期間（既定90日）を過ぎた run も再利用できない。
