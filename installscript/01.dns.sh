


sed -i '/DNS/d' /etc/systemd/resolved.conf
echo "DNS=$1" >> /etc/systemd/resolved.conf


systemctl daemon-reload
systemctl restart systemd-resolved
systemctl enable systemd-resolved
systemctl restart NetworkManager