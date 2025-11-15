if [[ -z "$1" ]]; then
    echo "镜像仓库地址不能为空"
    exit 0
fi

tar -zxf docker-20.10.9.tgz
cp ./docker/* /usr/bin


cat << EOF |  tee /etc/systemd/system/docker.service > /dev/null
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target
[Service]
Type=notify
# the default is not to use systemd for cgroups because the delegate issues still
# exists and systemd currently does not support the cgroup feature set required
# for containers run by docker
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
# Uncomment TasksMax if your systemd version supports it.
# Only systemd 226 and above support this version.
#TasksMax=infinity
TimeoutStartSec=0
# set delegate yes so that systemd does not reset the cgroups of docker containers
Delegate=yes
# kill only the docker process, not all processes in the cgroup
KillMode=process
# restart the docker process if it exits prematurely
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF


mkdir -p /etc/docker
mkdir -p /data/docker_root

cat << EOF | sudo tee /etc/docker/daemon.json > /dev/null
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "insecure-registries": [ "registry:5000","$1:5000"],
  "data-root": "/data/docker_root",
  "storage-driver": "overlay2",
"log-opts": {
    "max-size": "500m",
    "max-file": "3"
  }
}
EOF



systemctl daemon-reload > /dev/null 2>&1
systemctl enable docker --now > /dev/null 2>&1
systemctl restart systemd-resolved > /dev/null 2>&1
chmod 666 /var/run/docker.sock

if  systemctl status docker | grep Active | grep running | wc -l | grep -q "1"; then
    echo "【SUCCESS】：docker启动成功"
else
    echo "【ERROR】：docker启动失败"
fi

if systemctl list-unit-files -t service | grep docker | awk '{print $NF}' | grep -q "enabled"; then
    echo "【SUCCESS】：docker已开启自启动"
else
    echo "【ERROR】：docker没有配置自启动，请检查！"
fi

if docker info | wc -l | grep -q "53"; then
    echo "【SUCCESS】：docker info执行正常"
else
    echo "【ERROR】：docker info执行不正常，请检查相关配置！"
fi

if [ -e "/var/run/docker.sock" ]; then
    # 获取文件权限并转换为八进制数
    perms=$(stat -c '%a' /var/run/docker.sock)

    # 比较权限是否为666
    if [ "$perms" -eq 666 ]; then
        echo "【SUCCESS】：docker.sock权限为$perms"
    else
        echo "【ERROR】：docker.sock权限为$perms 请检查/var/run/docker.sock"
    fi
else
    echo "【ERROR】：/var/run/docker.sock文件不存在"
fi