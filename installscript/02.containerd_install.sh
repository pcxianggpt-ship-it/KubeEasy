## $1 为镜像仓库ip

if [ -z $1 ];then

  echo "缺少镜像仓库配置"
  exit 1
fi

registry=$1
echo "镜像仓库ip为 $1"

cd /tmp/k8s/02.container_runtime
#解压containerd-1.7.18-linux-amd64.tar.gz
tar Cxzvf /usr/local containerd-1.7.18-linux-amd64.tar.gz
#创建containerd自启service
cp containerd.service /etc/systemd/system/containerd.service
#安装runc
install -m 755 runcv1.3.3.amd64 /usr/local/sbin/runc
#安装cni-plugins
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.8.0.tgz
#生成默认配置文件
mkdir -p /etc/containerd
cp config.toml /etc/containerd/config.toml
#安装buildkit
tar Cxzvf /usr/local buildkit-v0.25.2.linux-amd64.tar.gz
#创建buildkit自启服务并启动
cp buildkit.s* /etc/systemd/system/
systemctl daemon-reload
systemctl enable buildkit.service --now
#安装nerdctl
tar -zxf nerdctl-2.2.0-linux-amd64.tar.gz
chmod +x nerdctl
mv nerdctl /usr/local/bin/
#修改nerdctl0地址   使用jq修改 gateway  subnet

## 配置镜像仓库地址
mkdir -p /etc/containerd/certs.d/$registry:5000
cat > /etc/containerd/certs.d/$registry:5000/hosts.toml <<EOF
server = "http://$registry:5000"

[host."http://$registry:5000"]
  capabilities = ["pull", "resolve", "push"]
EOF

## 配置镜像仓库地址域名
mkdir -p /etc/containerd/certs.d/registry:5000
cat > /etc/containerd/certs.d/registry:5000/hosts.toml <<EOF
server = "http://registry:5000"

[host."http://registry:5000"]
  capabilities = ["pull", "resolve", "push"]
EOF

systemctl daemon-reload
systemctl enable --now containerd

## 验证containerd安装和启动状态
echo "验证containerd安装状态..."

# 检查containerd服务状态
if systemctl is-active --quiet containerd; then
    echo "✓ containerd服务运行正常"
else
    echo "✗ containerd服务未运行"
    exit 1
fi

# 检查containerd服务是否已启用
if systemctl is-enabled --quiet containerd; then
    echo "✓ containerd服务已设置为开机自启"
else
    echo "✗ containerd服务未设置为开机自启"
fi

# 检查containerd版本
containerd_version=$(containerd --version)
echo "✓ containerd版本: $containerd_version"

# 检查runc版本
runc_version=$(runc --version)
echo "✓ runc版本: $runc_version"

# 检查nerdctl版本
nerdctl_version=$(nerdctl version)
echo "✓ nerdctl版本: $nerdctl_version"

# 检查CNI插件
if [ -d "/opt/cni/bin" ] && [ "$(ls -A /opt/cni/bin)" ]; then
    echo "✓ CNI插件已安装"
else
    echo "✗ CNI插件安装失败"
fi

# 检查buildkit服务状态
if systemctl is-active --quiet buildkit; then
    echo "✓ buildkit服务运行正常"
else
    echo "✗ buildkit服务未运行"
fi

# 检查containerd配置文件
if [ -f "/etc/containerd/config.toml" ]; then
    echo "✓ containerd配置文件已创建"
else
    echo "✗ containerd配置文件不存在"
fi

# 检查镜像仓库配置
if [ -d "/etc/containerd/certs.d/$registry:5000" ] && [ -f "/etc/containerd/certs.d/$registry:5000/hosts.toml" ]; then
    echo "✓ 镜像仓库配置已创建"
else
    echo "✗ 镜像仓库配置失败"
fi

echo "containerd安装验证完成"

