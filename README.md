# Tlog GCS Uploader for Bastion Server

`tlog` を使用して、Google Compute Engine (GCE) 踏み台サーバー上の全セッション操作（標準入出力）を記録し、ログを直接 Google Cloud Storage (GCS) へ保存するためのソリューションです。

## 🚀 特徴

- **自動記録**: SSHログインと同時に `tlog-rec` が起動し、全操作を JSON 形式で記録。
- **堅牢な転送**: ターミナルのクローズボタンによる切断やタイムアウト（`SIGHUP`, `SIGTERM`）時も `trap` を介して確実にアップロード。
- **自動リカバリ**: 万が一転送に失敗しても、次回ログイン時に未送信ログを自動的にバックグラウンドで再送。
- **直接転送**: セッション終了時にログを直接 GCS へ保存。監査証跡の完全性を確保し、サーバー上からは自動削除。
- **高信頼性**: `gsutil` を採用し、Rocky Linux 8 等の環境で安定動作。

---

## 📋 前提条件

### 1. 対象 OS
- **Rocky Linux 8** (Google Optimized 推奨)

### 2. GCP 権限 (IAM)
GCE インスタンスのサービスアカウントに対し、以下のロールを付与したバケットへのアクセス権が必要です。
- `roles/storage.objectCreator` (ストレージ オブジェクト作成者)
- `roles/storage.legacyBucketReader` (ストレージ レガシー バケット読み取り)

### 3. アクセススコープ (重要)
GCE インスタンスの設定で、以下のいずれかの **アクセススコープ** が有効である必要があります。
- 「すべての Cloud API に完全なアクセス権を許可」 (`cloud-platform`)
- 「ストレージ: 読み書き」 (`devstorage.read_write`)

> [!IMPORTANT]
> アクセススコープが「既定（ストレージが読み取り専用）」の場合、IAM権限が正しくてもアップロードに失敗します。

---

## 📦 インストールと設定

### 1. 依存パッケージの導入
```bash
sudo dnf update -y
sudo dnf install -y tlog google-cloud-cli
```

### 2. スクリプトの配置と設定
`tlog-gcs-uploader.sh` 内の `GCS_BUCKET` 変数を、ご自身のバケット名（例: `gs://YOUR_BUCKET_NAME`）に書き換えてください。

### 3. デプロイの実行
```bash
chmod +x deploy.sh
sudo ./deploy.sh
```

`deploy.sh` は以下の処理を行います：
- スクリプトの配置 (`/usr/local/bin/`)
- `sshd_config` への `ForceCommand` 適用
- ログ用一時ディレクトリの作成と権限設定 (`1733` スティッキービット)

### 4. 設定の反映
```bash
sudo systemctl restart sshd
```

---

## 🛠️ 運用と監査

### ログの再生
監査時に GCS からログをダウンロードし、`tlog-play` を使用して内容を再現できます。

```bash
# ログの取得
gsutil cp gs://YOUR_BUCKET_NAME/<user>/<file> ./

# ターミナル操作の再現
tlog-play --reader=file --file-path=<file>
```

### アップロード失敗時のリカバリ
ネットワーク不通などで GCS への転送に失敗したログは `/var/log/tlog-sessions/` に残ります。以下のコマンドで再試行可能です。

```bash
# 失敗ログの再アップロード
gsutil cp /var/log/tlog-sessions/*.log gs://YOUR_BUCKET_NAME/retry/ && rm -f /var/log/tlog-sessions/*.log
```

---

## 🔍 トラブルシューティング

### ログイン直後にセッションが終了する
- `tlog` がインストールされているか確認してください。
- インスタンスのアクセススコープが「読み書き」以上になっているか確認してください。
- `/var/log/tlog-sessions/error.log` または `journalctl -t tlog-gcs-uploader` でエラー内容を確認してください。

### GCS へのアップロードが失敗する
- `gsutil cp` を手動で実行し、エラーメッセージを確認してください。
- `Provided scope(s) are not authorized.` と出る場合は、インスタンスを停止してアクセススコープを `cloud-platform` に変更してください。