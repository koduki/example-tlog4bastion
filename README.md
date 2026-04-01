# Tlog GCS Uploader for Bastion Server

`tlog` を使用して、Google Compute Engine (GCE) 踏み台サーバー上の全セッションを記録し、ログを直接 Google Cloud Storage (GCS) へアップロードするためのソリューションです。

## 🚀 概要

このプロジェクトは、強力な監査証跡を確保するために以下の仕組みを提供します。

1.  **sshd ForceCommand**: ログイン時に自動的に記録スクリプトを実行。
2.  **tlog-rec**: 全てのターミナル操作（入力/出力）を JSON 形式で詳細に記録。
3.  **自動アップロード**: セッション終了時、ログを GCS へ即座に転送し、ローカルから削除。

---

## 🛠️ 構成ファイル

- **`tlog-gcs-uploader.sh`**: セッション記録と GCS アップロードのメインロジック。
- **`sshd_config`**: `ForceCommand` を用いた記録強制の設定。
- **`deploy.sh`**: 各コンポーネントを配置し、適切な権限を設定するスクリプト。

---

## 📋 前提条件

- **OS**: Rocky Linux 8 (Google Optimized 推奨)
- **GCP 権限**:
  - GCE インスタンスのサービスアカウントに `Storage Object Creator` (ストレージ オブジェクト作成者) 権限を付与。
  - **重要**: インスタンスの **アクセススコープ** で「ストレージ」の書き込みが許可されていること。
- **GCS バケット**: ログ保存用のバケット（例: `gs://YOUR_BUCKET_NAME`）。

---

## 📦 インストール方法

1.  **設定の変更**:
    `tlog-gcs-uploader.sh` を開き、`GCS_BUCKET` 変数を自分のバケット名に書き換えます。

2.  **依存パッケージの導入**:
    ```bash
    sudo dnf install -y tlog
    ```

3.  **デプロイの実行**:
    ```bash
    chmod +x deploy.sh
    ./deploy.sh
    ```

4.  **SSHD の再起動**:
    ```bash
    sudo systemctl restart sshd
    ```

---

## 🔍 トラブルシューティング

ログイン直後にセッションが終了する場合、以下の点を確認してください。

1.  **tlog の有無**:
    `sudo dnf install -y tlog` が実行されているか確認してください。
2.  **アクセススコープ**:
    インスタンスの変更画面で、アクセススコープが **「すべての Cloud API に完全なアクセス権を許可」** もしくは **「ストレージ: 読み書き」** になっているか確認してください。
3.  **エラーログ**:
    `/var/log/tlog-sessions/error.log` または `journalctl -t tlog-gcs-uploader` を確認してください。