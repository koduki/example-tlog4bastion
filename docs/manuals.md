# GCP環境におけるRocky Linux 8を用いたtlogによるセッション操作ログのGCS直接転送

## 1. 概要

本ドキュメントは、GCP上のGoogle Compute Engine (GCE) 踏み台サーバーにおいて、`tlog` を使用してユーザーの全操作ログを記録し、セッション終了時に直接 Google Cloud Storage (GCS) へ保存するための構築手順をまとめたものです。

セキュリティ要件に基づき、Cloud Loggingを介さず直接GCSへアップロードする構成とし、可用性と監査性を高めています。

## 2. 環境構築と依存関係の解消

### 2.1. 必要なソフトウェアのインストール

Rocky Linux 8の標準リポジトリから `tlog` をインストールします。

```bash
# システムの更新とtlogのインストール
sudo dnf update -y
sudo dnf install -y tlog
```

## 3. IAM権限とサービスアカウントの設定

GCEインスタンスのリソースがGCSへ書き込むための最小権限を付与します。

| ロール名 | 内容 | 用途 |
| :--- | :--- | :--- |
| `roles/storage.objectCreator` | オブジェクト作成権限 | ログのアップロード |
| `roles/storage.legacyBucketReader` | バケットのメタデータ読み取り | アップロード時のバケット確認 |

> [!IMPORTANT]
> **アクセススコープの確認**
> インスタンス設定の「アクセススコープ」で、「すべての Cloud API に完全なアクセス権を許可」または「ストレージ: 読み書き」が設定されている必要があります。アクセススコープが「既定」のまま（ストレージが読み取り専用）だと、IAM権限があってもアップロードに失敗します。

## 4. 設定とデプロイ

リポジトリに含まれるスクリプト (`tlog-gcs-uploader.sh`, `deploy.sh`) を使用して設定とデプロイを行います。

### 4.1. スクリプトの構成設定

`tlog-gcs-uploader.sh` を開き、`GCS_BUCKET` 変数をご自身のバケット名に変更します。

```bash
# tlog-gcs-uploader.sh 内の編集箇所
readonly GCS_BUCKET="gs://YOUR_BUCKET_NAME"  # ログ保存先の GCS バケット名に変更
```

このスクリプトは以下の主要な機能を備えています。
- **セッション記録**: `tlog-rec` を使用して操作を JSON 形式で記録。
- **堅牢なトラップ**: `HUP`, `TERM`, `EXIT` シグナルをトラップし、セッション終了を確実に検知。
- **自動アップロード**: セッション終了時にログを GCS へ自動転送し、ローカルから削除。
- **自動リカバリ**: 過去に転送失敗したログがある場合、次回のログイン時にバックグラウンドで再送を試行。
- **詳細ログ**: syslog (`logger`) を通じて、`journalctl` で動作状況を確認可能。

### 4.2. デプロイの実行

`deploy.sh` を実行して、スクリプトの配置と SSHD の設定適用を一括で行います。

```bash
# デプロイスクリプトの実行
chmod +x deploy.sh
sudo ./deploy.sh
```

`deploy.sh` は内部的に以下の処理を安全に行います。
- スクリプトの配置 (`/usr/local/bin/tlog-gcs-uploader.sh`)
- 適切な所有権と実行権限の設定 (`root:root`, `755`)
- ログ用一時ディレクトリ (`/var/log/tlog-sessions`) の作成と権限設定 (`1733` スティッキービット)
- `sshd_config` への `ForceCommand` 適用の反映
- `sshd -t` による設定の事前バリデーション
- `sshd` の自動再起動


## 5. SSHDの統合: ForceCommandによる強制適用

`/etc/ssh/sshd_config` に以下の設定を追加し、ログイン時にスクリプトを強制的に介するようにします。

```text
# 全ユーザーに適用する場合
ForceCommand /usr/local/bin/tlog-gcs-uploader.sh
```

設定反映：
```bash
sudo systemctl restart sshd
```

## 6. 運用・監査手順

### 6.1. アップロード失敗時のリカバリ
`/var/log/tlog-sessions/` に残った未アップロードのログは、以下のコマンドで手動再試行が可能です。

```bash
# 失敗ログの再アップロード
gsutil cp /var/log/tlog-sessions/*.log gs://YOUR_BUCKET_NAME/retry/ && rm -f /var/log/tlog-sessions/*.log
```

### 6.2. ログの再生
監査時には GCS からログをダウンロードし、`tlog-play` を使用します。

```bash
# ログの取得
gsutil cp gs://YOUR_BUCKET_NAME/<user>/<file> ./

# 再生 (ターミナル入出力を再現)
tlog-play --reader=file --file-path=<file>
```
\*ALL\* Logging : r/linuxadmin \- Reddit, accessed April 1, 2026, [https://www.reddit.com/r/linuxadmin/comments/6m8p4x/ssh\_jumpbox\_with\_all\_logging/](https://www.reddit.com/r/linuxadmin/comments/6m8p4x/ssh_jumpbox_with_all_logging/)  
7. Uploading to Google Cloud Storage With Complete Logging (Bash) \- Medium, accessed April 1, 2026, [https://medium.com/@surajranajitbhosale003/uploading-to-google-cloud-storage-with-complete-logging-bash-442e3461380c](https://medium.com/@surajranajitbhosale003/uploading-to-google-cloud-storage-with-complete-logging-bash-442e3461380c)  
8. SSH – Force Command execution on login even without Shell \- Stack Overflow, accessed April 1, 2026, [https://stackoverflow.com/questions/33713680/ssh-force-command-execution-on-login-even-without-shell](https://stackoverflow.com/questions/33713680/ssh-force-command-execution-on-login-even-without-shell)  
9. Tlog session recording | RHEL and CentOS \- CottonLinux, accessed April 1, 2026, [https://cottonlinux.com/tlog/](https://cottonlinux.com/tlog/)  
10. Chapter 3\. Playing back recorded sessions \- Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_enterprise\_linux/8/html/recording\_sessions/playing-back-a-recorded-session-getting-started-with-session-recording](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/recording_sessions/playing-back-a-recorded-session-getting-started-with-session-recording)  
11. Logging All SSH Commands & Sessions on a Bastion Host | by V Ananda Raj | Medium, accessed April 1, 2026, [https://v-ananda-raj.medium.com/logging-all-ssh-commands-sessions-on-a-bastion-host-9a8ba0a0f9af](https://v-ananda-raj.medium.com/logging-all-ssh-commands-sessions-on-a-bastion-host-9a8ba0a0f9af)  
12. How to Handle Signal Trapping in Bash \- OneUptime, accessed April 1, 2026, [https://oneuptime.com/blog/post/2026-01-24-bash-signal-trapping/view](https://oneuptime.com/blog/post/2026-01-24-bash-signal-trapping/view)  
13. How to Record SSH Sessions Established Through a Bastion Host | AWS Security Blog, accessed April 1, 2026, [https://aws.amazon.com/blogs/security/how-to-record-ssh-sessions-established-through-a-bastion-host/](https://aws.amazon.com/blogs/security/how-to-record-ssh-sessions-established-through-a-bastion-host/)