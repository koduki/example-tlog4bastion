sudo cp sshd_config /etc/ssh/sshd_config
sudo cp tlog-gcs-uploader.sh /usr/local/bin/tlog-gcs-uploader.sh
sudo chmod +x /usr/local/bin/tlog-gcs-uploader.sh
sudo mkdir -p /var/log/tlog-sessions
sudo chmod 1733 /var/log/tlog-sessions