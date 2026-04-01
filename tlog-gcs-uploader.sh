#!/bin/bash
# /usr/local/bin/tlog-gcs-uploader.sh
#
# SSH セッションを tlog-rec で記録し、終了時に GCS へアップロードするスクリプト。
# sshd_config の ForceCommand から呼び出される。

set -uo pipefail

# =================================================================
# 1. 構成設定
# =================================================================
readonly GCS_BUCKET="gs://gcs-example-tlog001"  # ログ保存先の GCS バケット名
readonly LOCAL_TMP_DIR="/var/log/tlog-sessions"
readonly SYSLOG_TAG="tlog-gcs-uploader"

readonly USER_NAME="${USER:-$(whoami)}"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly SESSION_ID="${PPID}"
readonly LOG_FILE="${LOCAL_TMP_DIR}/${USER_NAME}_${TIMESTAMP}_${SESSION_ID}.log"

# =================================================================
# 2. ログ出力関数
#    デバッグログ: journalctl -t tlog-gcs-uploader -p debug -f
#    エラーログ:   journalctl -t tlog-gcs-uploader -p err -f
# =================================================================
log_debug() { logger -p user.debug -t "${SYSLOG_TAG}" "[user=${USER_NAME}] [pid=$$] $1"; }
log_error() { logger -p user.err   -t "${SYSLOG_TAG}" "[user=${USER_NAME}] [pid=$$] $1"; }

# =================================================================
# 3. 事前準備
# =================================================================
if [[ ! -d "${LOCAL_TMP_DIR}" ]]; then
    mkdir -p "${LOCAL_TMP_DIR}"
    chmod 1733 "${LOCAL_TMP_DIR}"
fi

log_debug "Session started. log_file=${LOG_FILE}"

# =================================================================
# 4. アップロード処理（シグナル受信時 or EXIT 時に呼ばれる）
# =================================================================
_UPLOAD_DONE=false

cleanup_and_upload() {
    local signal="${1:-EXIT}"

    # 重複実行防止
    if "${_UPLOAD_DONE}"; then
        log_debug "cleanup_and_upload: already completed, skipping. (signal=${signal})"
        return
    fi
    _UPLOAD_DONE=true

    log_debug "cleanup_and_upload: triggered by signal=${signal}"

    # アップロード中にシグナルで kill されるのを防ぐ
    trap '' HUP TERM

    if [[ ! -f "${LOG_FILE}" ]]; then
        log_debug "cleanup_and_upload: log file not found, nothing to upload."
        return
    fi

    local filesize
    filesize=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo "0")

    if [[ "${filesize}" -eq 0 ]]; then
        log_debug "cleanup_and_upload: log file is empty, removing without upload."
        rm -f "${LOG_FILE}"
        return
    fi

    log_debug "cleanup_and_upload: uploading ${filesize} bytes to ${GCS_BUCKET}/${USER_NAME}/"
    local gcloud_out
    if gcloud_out=$(/usr/bin/gsutil cp "${LOG_FILE}" "${GCS_BUCKET}/${USER_NAME}/" 2>&1); then
        log_debug "cleanup_and_upload: upload SUCCESS, removing local file."
        rm -f "${LOG_FILE}"
    else
        log_error "cleanup_and_upload: upload FAILED. output=${gcloud_out}"
    fi
}

# シグナルごとに引数を渡してトリガー元を記録する
trap 'cleanup_and_upload HUP'  HUP
trap 'cleanup_and_upload TERM' TERM
trap 'cleanup_and_upload EXIT' EXIT

# =================================================================
# 5. 未送信ログの再送（バックグラウンド）
# =================================================================
resend_pending_logs() {
    local f
    for f in "${LOCAL_TMP_DIR}/${USER_NAME}_"*.log; do
        [[ -f "${f}" && "${f}" != "${LOG_FILE}" ]] || continue
        (
            if /usr/bin/gsutil cp "${f}" "${GCS_BUCKET}/${USER_NAME}/" >/dev/null 2>&1; then
                rm -f "${f}"
                logger -p user.debug -t "${SYSLOG_TAG}" "[user=${USER_NAME}] resend SUCCESS: ${f}"
            else
                logger -p user.err -t "${SYSLOG_TAG}" "[user=${USER_NAME}] resend FAILED: ${f}"
            fi
        ) &
    done
}

resend_pending_logs

# =================================================================
# 6. セッション記録の開始
# =================================================================
REAL_SHELL=$(getent passwd "${USER_NAME}" | cut -d: -f7)
readonly REAL_SHELL="${REAL_SHELL:-/bin/bash}"
log_debug "real_shell=${REAL_SHELL}"

if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    log_debug "Non-interactive command: ${SSH_ORIGINAL_COMMAND}. Executing directly."
    exec "${REAL_SHELL}" -c "${SSH_ORIGINAL_COMMAND}"
fi

log_debug "Starting tlog-rec for interactive session."
tlog_exit_code=0
/usr/bin/tlog-rec --writer=file --file-path="${LOG_FILE}" -- "${REAL_SHELL}" -l || tlog_exit_code=$?
log_debug "tlog-rec exited with code=${tlog_exit_code}"
