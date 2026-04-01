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

### 2.2. Google Cloud CLI (gcloud) の準備

「Rocky Linux Optimized for Google Cloud」イメージを使用している場合、最新版を導入・更新してください。

```bash
# 最新のgcloud storageコマンドを利用するための更新
sudo dnf update -y google-cloud-cli
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

## 4. セッション管理スクリプトの実装

セッション終了を `trap` で検知し、ログをGCSバケットへ転送するスクリプトを作成します。

### 4.1. スクリプトの作成: `/usr/local/bin/tlog-gcs-uploader.sh`

```bash
#!/bin/bash
# /usr/local/bin/tlog-gcs-uploader.sh

# =================================================================
# 1. 構成設定
# =================================================================
GCS_BUCKET="gs://YOUR_BUCKET_NAME" # 自分のバケット名に変更
LOCAL_TMP_DIR="/var/log/tlog-sessions"
ERROR_LOG="${LOCAL_TMP_DIR}/error.log"
USER_NAME=${USER:-$(whoami)}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SESSION_ID=${PPID}
LOG_FILE="${LOCAL_TMP_DIR}/${USER_NAME}_${TIMESTAMP}_${SESSION_ID}.log"

# エラー出力用関数の定義
log_error() {
    local message="$1"
    local ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${ts}] ERROR: ${message}" >> "${ERROR_LOG}"
    logger -t tlog-gcs-uploader "ERROR: ${message}"
}

# =================================================================
# 2. 事前準備
# =================================================================
if [ ! -d "${LOCAL_TMP_DIR}" ]; then
    # 通常はdeploy.shで作成済み
    mkdir -p "${LOCAL_TMP_DIR}"
    chmod 1733 "${LOCAL_TMP_DIR}"
fi

# =================================================================
# 3. アップロード処理
# =================================================================
cleanup_and_upload() {
    # すでに処理中の場合は重複実行を避ける
    if [ "${UP_PROCESSING}" = "true" ]; then return; fi
    export UP_PROCESSING="true"

    if [ -f "${LOG_FILE}" ] && [ -s "${LOG_FILE}" ]; then
        # GCSへの転送を試行
        /usr/bin/gsutil cp "${LOG_FILE}" "${GCS_BUCKET}/${USER_NAME}/" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            rm -f "${LOG_FILE}"
        else
            log_error "GCS upload failed on exit for ${LOG_FILE}"
        fi
    else
        # ファイルがない、または空の場合は削除
        rm -f "${LOG_FILE}"
    fi
}

# 未アップロードの古いログがあれば再送する
resend_pending_logs() {
    for f in "${LOCAL_TMP_DIR}/${USER_NAME}_"*.log; do
        if [ -f "$f" ] && [ "$f" != "${LOG_FILE}" ]; then
            ( /usr/bin/gsutil cp "$f" "${GCS_BUCKET}/${USER_NAME}/" && rm -f "$f" ) > /dev/null 2>&1 &
        fi
    done
}

# 終了シグナルを確実にトラップ（EXITに加え、HUP, TERMも明示）
trap cleanup_and_upload EXIT HUP TERM

# =================================================================
# 4. セッション記録の開始
# =================================================================
# ログイン時に未アップロードのログがあればバックグラウンドで処理
resend_pending_logs

REAL_SHELL=$(getent passwd "${USER_NAME}" | cut -d: -f7)
[ -z "${REAL_SHELL}" ] && REAL_SHELL="/bin/bash"

if [ -n "${SSH_ORIGINAL_COMMAND}" ]; then
    # 非対話型実行(scp等)は直接実行
    exec "${REAL_SHELL}" -c "${SSH_ORIGINAL_COMMAND}"
else
    # 対話型セッションの記録
    /usr/bin/tlog-rec --writer=file --file-path="${LOG_FILE}" -- "${REAL_SHELL}" -l
fi
```

### 4.2. 権限とディレクトリの設定

```bash
# スクリプトの所有権と実行権付与
sudo chown root:root /usr/local/bin/tlog-gcs-uploader.sh
sudo chmod 755 /usr/local/bin/tlog-gcs-uploader.sh

# 一時ログ保存ディレクトリ（スティッキービットで保護）
sudo mkdir -p /var/log/tlog-sessions
sudo chmod 1733 /var/log/tlog-sessions
```

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