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

# =================================================================
# 2. ログ出力関数
#    journalctl -t tlog-gcs-uploader -f  でリアルタイム確認できる
# =================================================================
log_info() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] INFO:  [PID=$$] ${message}" >> "${ERROR_LOG}"
    logger -t tlog-gcs-uploader "INFO: [user=${USER_NAME}] [pid=$$] ${message}"
}

log_error() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] ERROR: [PID=$$] ${message}" >> "${ERROR_LOG}"
    logger -t tlog-gcs-uploader "ERROR: [user=${USER_NAME}] [pid=$$] ${message}"
}

# =================================================================
# 3. 事前準備
# =================================================================
if [ ! -d "${LOCAL_TMP_DIR}" ]; then
    mkdir -p "${LOCAL_TMP_DIR}"
    chmod 1733 "${LOCAL_TMP_DIR}"
fi

log_info "Session started. log_file=${LOG_FILE}"

# =================================================================
# 4. アップロード処理（シグナル受信時 or EXIT 時に呼ばれる）
# =================================================================
cleanup_and_upload() {
    local signal="${1:-EXIT}"

    # 重複実行防止
    if [ "${UP_PROCESSING}" = "true" ]; then
        log_info "cleanup_and_upload: already in progress, skipping. (signal=${signal})"
        return
    fi
    export UP_PROCESSING="true"

    log_info "cleanup_and_upload: triggered by signal=${signal}"

    # ハンドラ内でシグナルを無視 → gsutil が途中で殺されるのを防ぐ
    trap '' HUP TERM
    log_info "cleanup_and_upload: HUP/TERM signals suppressed for upload"

    if [ ! -f "${LOG_FILE}" ]; then
        log_info "cleanup_and_upload: log file not found: ${LOG_FILE}"
        return
    fi

    local filesize
    filesize=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo "unknown")
    log_info "cleanup_and_upload: log file exists. size=${filesize} bytes"

    if [ -s "${LOG_FILE}" ]; then
        log_info "cleanup_and_upload: starting gsutil upload to ${GCS_BUCKET}/${USER_NAME}/"
        GCLOUD_OUT=$(/usr/bin/gsutil cp "${LOG_FILE}" "${GCS_BUCKET}/${USER_NAME}/" 2>&1)
        local exit_code=$?
        if [ ${exit_code} -eq 0 ]; then
            log_info "cleanup_and_upload: upload SUCCESS. removing local file."
            rm -f "${LOG_FILE}"
        else
            log_error "cleanup_and_upload: upload FAILED (exit_code=${exit_code}). output=${GCLOUD_OUT}"
        fi
    else
        log_info "cleanup_and_upload: log file is empty, removing without upload."
        rm -f "${LOG_FILE}"
    fi
}

# シグナルごとに引数を渡してトリガー元を記録する
trap 'cleanup_and_upload HUP'  HUP
trap 'cleanup_and_upload TERM' TERM
trap 'cleanup_and_upload EXIT' EXIT

# =================================================================
# 5. セッション記録の開始
# =================================================================
REAL_SHELL=$(getent passwd "${USER_NAME}" | cut -d: -f7)
[ -z "${REAL_SHELL}" ] && REAL_SHELL="/bin/bash"
log_info "real_shell=${REAL_SHELL}"

if [ -n "${SSH_ORIGINAL_COMMAND}" ]; then
    log_info "non-interactive command detected: ${SSH_ORIGINAL_COMMAND}. executing directly."
    exec "${REAL_SHELL}" -c "${SSH_ORIGINAL_COMMAND}"
else
    log_info "starting tlog-rec for interactive session."
    /usr/bin/tlog-rec --writer=file --file-path="${LOG_FILE}" -- "${REAL_SHELL}" -l
    log_info "tlog-rec exited with code=$?"
fi
