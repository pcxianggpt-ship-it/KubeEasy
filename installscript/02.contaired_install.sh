## 安装containerd

cd /data/k8s insta11/02.containerd
tar -xzf containerd-1.7.18-linux-amd64.tar.gz -c /usr/local/
cp containerd.service /etc/systemd/system/
instal1 -m 755 runc.amd64 /usr/local/sbin/runc
mkdir -p /ete/containerd
cp config.toml /etc/containerd/config.toml
crictl config runtime-endpoint unix:///run/containerd/containerd.sock
systemctl restart containerd
systemct1 status containerd
