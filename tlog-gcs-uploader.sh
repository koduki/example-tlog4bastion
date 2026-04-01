#!/bin/bash
# /usr/local/bin/tlog-gcs-uploader.sh

# =================================================================
# 1. 構成設定
# =================================================================
GCS_BUCKET="gs://gcs-example-tlog001" # ログ保存先のGCSバケット名に変更してください
LOCAL_TMP_DIR="/var/log/tlog-sessions"
ERROR_LOG="/var/log/tlog-error.log"
INSTANCE_NAME=$(hostname)
USER_NAME=${USER:-$(whoami)}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SESSION_ID=${PPID}
LOG_FILE="${LOCAL_TMP_DIR}/${USER_NAME}_${TIMESTAMP}_${SESSION_ID}.log"

# エラー出力用関数の定義
log_error() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    # ローカルファイルとsyslogの両方に出力
    echo "[${timestamp}] ERROR: ${message}" >> "${ERROR_LOG}"
    logger -t tlog-gcs-uploader "ERROR: ${message}"
}

# =================================================================
# 2. 事前準備
# =================================================================
if [ ! -d "${LOCAL_TMP_DIR}" ]; then
    mkdir -p "${LOCAL_TMP_DIR}"
    chmod 1733 "${LOCAL_TMP_DIR}" # スティッキービットを立て、他人のログを消せないようにする
fi

# =================================================================
# 3. アップロード処理
# =================================================================
cleanup_and_upload() {
    # すでに処理中の場合は重複実行を避ける
    if [ "${UP_PROCESSING}" = "true" ]; then return; fi
    export UP_PROCESSING="true"

    # ★ここが重要:
    # SIGHUP/SIGTERMのハンドラ内では、子プロセス(gsutil)にも同じシグナルが
    # 届いてアップロードが中断されてしまう。
    # ハンドラ内でシグナルを無視することでgsutilを保護する。
    trap '' HUP TERM

    if [ -f "${LOG_FILE}" ] && [ -s "${LOG_FILE}" ]; then
        /usr/bin/gsutil cp "${LOG_FILE}" "${GCS_BUCKET}/${USER_NAME}/" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            rm -f "${LOG_FILE}"
        else
            log_error "GCS upload failed on exit for ${LOG_FILE}"
        fi
    else
        rm -f "${LOG_FILE}"
    fi
}

# セッション切断(SIGHUP)・強制終了(SIGTERM)・通常終了(EXIT)をすべて検知してアップロード
trap cleanup_and_upload EXIT HUP TERM

# =================================================================
# 4. セッション記録の開始
# =================================================================

# 本来のシェルの特定
REAL_SHELL=$(getent passwd "${USER_NAME}" | cut -d: -f7)
[ -z "${REAL_SHELL}" ] && REAL_SHELL="/bin/bash"

# 非対話型実行(scp等)の考慮
if [ -n "${SSH_ORIGINAL_COMMAND}" ]; then
    # scpやrsync等の場合は記録せずに直接実行
    exec "${REAL_SHELL}" -c "${SSH_ORIGINAL_COMMAND}"
else
    # 対話型セッションの記録
    # tlog-rec終了後、trapによりcleanup_and_uploadが実行される
    /usr/bin/tlog-rec --writer=file --file-path="${LOG_FILE}" -- "${REAL_SHELL}" -l
fi

