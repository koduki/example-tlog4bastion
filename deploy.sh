#!/bin/bash
# deploy.sh — tlog-gcs-uploader の配置と sshd 設定の適用
#
# 使い方:
#   chmod +x deploy.sh
#   sudo ./deploy.sh

set -euo pipefail

# ------------------------------------------------------------------
# 色付きログ出力
# ------------------------------------------------------------------
info()  { echo -e "\e[32m[INFO]\e[0m  $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

# ------------------------------------------------------------------
# root 権限チェック
# ------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    error "このスクリプトは root 権限で実行してください: sudo ./deploy.sh"
    exit 1
fi

# ------------------------------------------------------------------
# スクリプトの配置
# ------------------------------------------------------------------
info "tlog-gcs-uploader.sh を /usr/local/bin/ へコピー..."
cp tlog-gcs-uploader.sh /usr/local/bin/tlog-gcs-uploader.sh
chown root:root /usr/local/bin/tlog-gcs-uploader.sh
chmod 755 /usr/local/bin/tlog-gcs-uploader.sh

# ------------------------------------------------------------------
# ログ用ディレクトリの作成
# ------------------------------------------------------------------
info "ログ用ディレクトリ /var/log/tlog-sessions/ を準備..."
mkdir -p /var/log/tlog-sessions
chmod 1733 /var/log/tlog-sessions

# ------------------------------------------------------------------
# sshd_config のバリデーションと配置
# ------------------------------------------------------------------
info "sshd_config を /etc/ssh/sshd_config へコピー..."
cp sshd_config /etc/ssh/sshd_config

info "sshd_config を検証中..."
if ! sshd -t; then
    error "sshd_config の検証に失敗しました。設定を確認してください。"
    exit 1
fi
info "sshd_config の検証 OK"

# ------------------------------------------------------------------
# sshd の再起動
# ------------------------------------------------------------------
info "sshd を再起動..."
systemctl restart sshd
info "sshd の再起動完了"

echo ""
info "デプロイが完了しました。"