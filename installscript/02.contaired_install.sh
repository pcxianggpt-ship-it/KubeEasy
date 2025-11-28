## $1 为安装目录路径

cd $1/02.contrainer_runtime/containered/
#解压containerd-2.1.4-linux-amd64.tar.gz
tar Cxzvf /usr/local containerd-2.1.4-linux-amd64.tar.gz
#创建containerd自启service
cp containerd.service /etc/systemd/system/containerd.service
#安装runc
install -m 755 runcv1.3.3.amd64 /usr/local/sbin/runc
#安装cni-plugins
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.8.0.tgz
#生成默认配置文件
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
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
##
##
cat /etc/cni/net.d/nerdctl-bridge.conflist


#修改containerd配置
vim /etc/containerd/config.toml


systemctl daemon-reload
systemctl enable --now containerd
