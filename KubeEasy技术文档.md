# KubeEasy 技术文档

> 版本：v1.0
> 日期：2025-11-15
> 作者：基于需求文档整理

## 目录

1. [系统概述](#1-系统概述)
2. [installer.sh 主控脚本](#2-installersh-主控脚本)
3. [tools.sh 工具库](#3-tools-工具库)
4. [step_*.sh 安装步骤](#4-stepsh-安装步骤)
5. [verify_*.sh 验证脚本](#5-verifysh-验证脚本)
6. [config.yaml 配置文件](#6-configyaml-配置文件)
7. [日志处理](#7-日志处理)
8. [目录结构](#8-目录结构)

## 1. 系统概述

KubeEasy 是一个 K8s 离线一键部署框架，旨在将现有的离线安装 shell 脚本改造成一套**可配置、可重入、支持并行/串行流程控制、带规范化日志和状态查询**的全流程自动化安装框架。

### 核心特性
- **离线部署**：完全不依赖外网，所有安装包预先上传
- **多发行版兼容**：支持 CentOS/RHEL、Kylin、Ubuntu 等
- **并行/串行控制**：智能任务调度，提高部署效率
- **状态管理**：完整的安装状态跟踪和恢复机制
- **配置驱动**：通过配置文件控制整个安装流程

## 2. installer.sh 主控脚本

### 2.1 流程控制逻辑

installer.sh 是整个系统的主控脚本，负责控制全流程安装。其核心流程控制逻辑如下：

#### 2.1.1 启动流程
```bash
1. 解析命令行参数
2. 检查运行环境（root权限、必要工具）
3. 加载配置文件 config.yaml
4. 初始化日志和状态目录
5. 验证配置文件完整性
```

#### 2.1.2 主执行流程
```bash
# 预检查阶段
- 检查是否为 root 用户
- 验证网络连通性
- 检查必要工具是否安装

# SSH免密登录配置（第一步）
- 基于 installscript/0.ssh_nopasswd.sh
- 必须在所有其他步骤前完成
- 支持密钥和密码两种认证方式

# 并行/串行任务调度
for step in $STEPS; do
    # 读取步骤配置（并发模式、依赖关系）
    step_config=$(get_step_config $step)

    if [[ "$step_config" == "parallel" ]]; then
        # 并行执行
        parallel_run "execute_step" "$HOSTS" "$CONCURRENCY"
    else
        # 串行执行
        for host in $HOSTS; do
            execute_step $host $step
        done
    fi
done
```

#### 2.1.3 步骤执行控制
```bash
execute_step() {
    local host=$1
    local step=$2

    # 1. 运行验证器
    verify_result=$(run_verify $host $step)

    if [[ "$verify_result" == "OK" ]]; then
        log "INFO" $step $host "Step already completed, skipping"
        return 0
    fi

    # 2. 执行安装脚本
    log "INFO" $step $host "Executing step..."
    if remote_exec $host "./steps/step_${step}.sh"; then
        # 3. 再次验证
        verify_result=$(run_verify $host $step)
        if [[ "$verify_result" == "OK" ]]; then
            update_status $host $step "COMPLETED"
        else
            update_status $host $step "FAILED" "Verification failed"
        fi
    else
        update_status $host $step "FAILED" "Installation failed"
    fi
}
```

#### 2.1.4 命令行接口
```bash
# 基本用法
./installer.sh install          # 执行完整安装流程
./installer.sh install --step install-docker  # 执行特定步骤
./installer.sh status           # 查看整体状态
./installer.sh status --host node-01  # 查看特定主机状态
./installer.sh status --step install-docker  # 查看特定步骤状态
./installer.sh logs [--tail N] [--host node-01]  # 查看日志
./installer.sh retry --host node-01 --step install-docker  # 重试失败步骤
```

## 3. tools.sh 工具库

tools.sh 是系统的通用工具集，提供各种辅助功能函数。

### 3.1 日志管理函数

```bash
# 统一日志输出函数
log() {
    local level=$1    # DEBUG/INFO/WARN/ERROR/FATAL
    local step=$2     # 步骤名称
    local host=$3     # 主机名
    local message=$4  # 日志消息

    local timestamp=$(date -Iseconds)
    echo "${timestamp} [${level}] [${host}] [step:${step}] ${message}" | \
        tee -a "${LOG_DIR}/installer_$(date +%Y%m%d).log"
}

# 日志轮转
rotate_logs() {
    local max_size=${1:-100M}
    find "$LOG_DIR" -name "*.log" -size "+$max_size" -exec gzip {} \;
}
```

### 3.2 远程执行函数

```bash
# 远程命令执行
remote_exec() {
    local host=$1
    local cmd=$2
    local timeout=${3:-300}

    if [[ -n "$SSH_KEY" ]]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=$timeout \
            "$SSH_USER@$host" "$cmd"
    else
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=$timeout "$SSH_USER@$host" "$cmd"
    fi
}

# 远程文件复制
scp_send() {
    local host=$1
    local src=$2
    local dst=$3

    if [[ -n "$SSH_KEY" ]]; then
        scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$src" "$SSH_USER@$host:$dst"
    else
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$src" "$SSH_USER@$host:$dst"
    fi
}
```

### 3.3 并发控制函数

```bash
# 并行执行控制
parallel_run() {
    local func=$1
    local hosts=$2
    local concurrency=${3:-8}

    local pids=()
    local active=0

    for host in $hosts; do
        # 控制并发数
        while [[ $active -ge $concurrency ]]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    wait "${pids[$i]}"
                    unset pids[$i]
                    ((active--))
                fi
            done
            sleep 1
        done

        # 启动新任务
        $func $host &
        pids+=($!)
        ((active++))
    done

    # 等待所有任务完成
    wait "${pids[@]}"
}
```

### 3.4 配置文件操作函数

```bash
# YAML 配置读取
yaml_get() {
    local path=$1
    local file=$2

    if command -v yq >/dev/null 2>&1; then
        yq eval "$path" "$file"
    else
        # 使用内置的简单 YAML 解析器
        echo "Warning: yq not found, using simple parser"
        simple_yaml_parser "$path" "$file"
    fi
}

# YAML 配置设置
yaml_set() {
    local path=$1
    local value=$2
    local file=$3

    yq eval "$path = $value" -i "$file"
}

# JSON 配置操作（类似函数）
json_get() { jq -r "$1" "$2"; }
json_set() { jq "$1 = $3" "$2" > tmp.json && mv tmp.json "$2"; }
```

### 3.5 验证函数

```bash
# 运行验证器
run_verify() {
    local host=$1
    local step=$2

    local verify_script="verify/verify_${step}.sh"
    if [[ -f "$verify_script" ]]; then
        remote_exec $host "bash $verify_script"
    else
        echo "NOT_OK"  # 如果没有验证器，默认返回未完成
    fi
}

# 状态更新
update_status() {
    local host=$1
    local step=$2
    local status=$3
    local message=${4:-""}

    local status_file="${STATUS_DIR}/${host}_${step}.json"

    cat > "$status_file" << EOF
{
    "host": "$host",
    "step": "$step",
    "status": "$status",
    "start_time": "$(date -Iseconds)",
    "end_time": "$(date -Iseconds)",
    "message": "$message",
    "retry_count": "$(get_retry_count $host $step)"
}
EOF
}
```

### 3.6 环境检测函数

```bash
# 操作系统检测
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    elif [[ -f /etc/lsb-release ]]; then
        echo "ubuntu"
    elif [[ -f /etc/kylin-release ]]; then
        echo "kylin"
    else
        echo "unknown"
    fi
}

# 架构检测
detect_arch() {
    case $(uname -m) in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

# 确保工具可用
ensure_tool() {
    local tool=$1
    local package_path="${PACKAGES_DIR}/07.tools/${tool}"

    if ! command -v "$tool" >/dev/null 2>&1; then
        if [[ -f "$package_path" ]]; then
            cp "$package_path" "/usr/local/bin/$tool"
            chmod +x "/usr/local/bin/$tool"
        else
            log "ERROR" "setup" "$(hostname)" "Tool $tool not found in packages"
            return 1
        fi
    fi
}
```

### 3.7 锁机制函数

```bash
# 获取文件锁
acquire_lock() {
    local lock_file=$1
    local timeout=${2:-60}

    local count=0
    while ! flock -n 9; do
        if [[ $count -ge $timeout ]]; then
            return 1
        fi
        sleep 1
        ((count++))
    done 9>"$lock_file"
}

# 释放文件锁
release_lock() {
    local lock_file=$1
    flock -u 9 2>/dev/null || true
}
```

## 4. step_*.sh 安装步骤

每个 step_*.sh 脚本对应一个具体的安装步骤，包含安装逻辑和错误处理。

### 4.1 step01_check_root.sh
```bash
#!/bin/bash
# 检查是否以 root 用户运行

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

echo "OK: Running as root"
```

### 4.2 step02_ssh_key.sh
```bash
#!/bin/bash
# SSH 免密登录配置（基于 installscript/0.ssh_nopasswd.sh）

# 1. 生成本地密钥对
if [[ ! -f ~/.ssh/id_rsa ]]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi

# 2. 分发公钥到所有节点
for host in $(get_all_hosts); do
    if ! sshpass -p "$SSH_PASS" ssh-copy-id -o StrictHostKeyChecking=no \
        "$SSH_USER@$host" 2>/dev/null; then
        echo "ERROR: Failed to copy SSH key to $host"
        exit 1
    fi
done

echo "OK: SSH key distribution completed"
```

### 4.3 step03_k8s_install.sh
```bash
#!/bin/bash
# Kubernetes 组件安装（基于 installscript/04.Dependency-Package-*.sh）

k8s_version=$(yaml_get '.global.kubernetes_version' config.yaml)
packages_dir=$(yaml_get '.global.packages_dir' config.yaml)
arch=$(detect_arch)

# 1. 安装 Kubernetes RPM 包
k8s_rpm_dir="${packages_dir}/01.rpm_package/k8s-${k8s_version}"

if [[ -d "$k8s_rpm_dir" ]]; then
    rpm -ivh ${k8s_rpm_dir}/*.rpm
else
    echo "ERROR: Kubernetes RPM packages not found"
    exit 1
fi

# 2. 安装系统依赖包
system_rpm_dir="${packages_dir}/01.rpm_package/system"
if [[ -d "$system_rpm_dir" ]]; then
    rpm -ivh ${system_rpm_dir}/*.rpm
fi

# 3. 替换 kubeadm 二进制（支持 99 年证书）
if [[ -f "${packages_dir}/01.rpm_package/kubeadm100y-${arch}/kubeadm" ]]; then
    cp /usr/bin/kubeadm /tmp/kubeadm
    cp "${packages_dir}/01.rpm_package/kubeadm100y-${arch}/kubeadm" /usr/bin/kubeadm
    chmod +x /usr/bin/kubeadm
fi

# 4. 配置 kubelet
mkdir -p /etc/kubernetes
cat > /etc/kubernetes/kubelet.env << EOF
KUBELET_KUBECONFIG_ARGS="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
KUBELET_CONFIG_ARGS="--config=/var/lib/kubelet/config.yaml"
KUBELET_SYSTEM_PODS_ARGS="--pod-manifest-path=/etc/kubernetes/manifests"
KUBELET_NETWORK_ARGS="--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"
KUBELET_DNS_ARGS="--cluster-dns=10.96.0.10 --cluster-domain=cluster.local"
KUBELET_AUTHZ_ARGS="--authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt"
KUBELET_CADVISOR_ARGS="--cadvisor-port=0"
KUBELET_CGROUP_ARGS="--cgroup-driver=systemd"
KUBELET_EXTRA_ARGS="--container-runtime=remote --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock"
EOF

# 5. 启用并启动 kubelet
systemctl enable kubelet
systemctl start kubelet || true  # kubelet 会在 join 集群后正常启动

echo "OK: Kubernetes components installation completed"
```

### 4.4 step04_env_prepare.sh
```bash
#!/bin/bash
# 系统环境准备（基于 installscript/01.set-env.sh）

# 1. 关闭 swap 分区
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 2. 停止并禁用防火墙
systemctl stop firewalld || true
systemctl disable firewalld || true

# 3. 卸载冲突的容器运行时
yum remove -y podman containerd || true

# 4. 配置内核模块
cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 5. 配置 sysctl 参数（包含IPv6支持）
# 先删除现有配置项，再写入新配置
sed -i '/net.bridge.bridge-nf-call-iptables/d' /etc/sysctl.conf
sed -i '/net.bridge.bridge-nf-call-ip6tables/d' /etc/sysctl.conf
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.netfilter.nf_conntrack_max/d' /etc/sysctl.conf
sed -i '/net.netfilter.nf_conntrack_tcp_timeout_established/d' /etc/sysctl.conf


# 追加新的配置项
cat >> /etc/sysctl.conf << EOF

# IPv4 参数
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# IPv6 参数
net.ipv6.conf.all.forwarding        = 1
net.ipv6.conf.all.disable_ipv6      = 0
net.ipv6.conf.default.disable_ipv6  = 0
net.ipv6.conf.lo.disable_ipv6       = 0

# 网络桥接参数
net.netfilter.nf_conntrack_max      = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF

# 6. 配置 IPv6 网卡信息
local_ipv6=$(yaml_get ".nodes[] | select(.id == \"$(hostname)\") | .ipv6" config.yaml)
if [[ -n "$local_ipv6" ]]; then
    # 获取主网卡名称
    primary_interface=$(ip route | grep default | awk '{print $5}' | head -n1)

    if [[ -n "$primary_interface" ]]; then
        # 配置网卡文件
        network_file="/etc/sysconfig/network-scripts/ifcfg-${primary_interface}"

        # 备份原文件
        if [[ -f "$network_file" ]]; then
            cp "$network_file" "${network_file}.backup.$(date +%Y%m%d_%H%M%S)"
        fi

        # 先删除现有配置项，再写入新配置
        if [[ -f "$network_file" ]]; then
            # 删除现有的 IPv6 相关配置项
            sed -i '/IPV6INIT/d' "$network_file"
            sed -i '/IPV6_AUTOCONF/d' "$network_file"
            sed -i '/IPV6ADDR/d' "$network_file"
            sed -i '/IPV6_DEFROUTE/d' "$network_file"
            sed -i '/IPV6_DEFAULTGW/d' "$network_file"
            sed -i '/IPV6_FAILURE_FATAL/d' "$network_file"
        else
                # 追加 IPv6 配置项
                cat >> "$network_file" << EOF
IPV6INIT=yes
IPV6_AUTOCONF=no
IPV6ADDR=$local_ipv6
IPV6_DEFROUTE=yes
IPV6_DEFAULTGW=fd00::1
IPV6_FAILURE_FATAL=no
EOF
        fi


        # 重启网络服务
        systemctl restart network || systemctl restart NetworkManager

        # 验证 IPv6 配置
        sleep 5
        if ip -6 addr show dev "$primary_interface" | grep -q "$local_ipv6"; then
            log "INFO" "env_prepare" "$(hostname)" "IPv6 configuration successful for interface $primary_interface"
        else
            log "ERROR" "env_prepare" "$(hostname)" "IPv6 configuration failed for interface $primary_interface"
        fi
    fi
fi

sysctl --system

echo "OK: Environment preparation completed"
```

### 4.5 step05_dns_config.sh
```bash
#!/bin/bash
# DNS 配置（基于 installscript/01.dns.sh）

local_ip=$(get_local_ip)
dns_server=$(yaml_get '.global.dns_server' config.yaml)


# 配置 /etc/resolv.conf
cat > /etc/resolv.conf << EOF
nameserver $dns_server
nameserver 8.8.8.8
search localdomain
EOF

# 添加 IPv6 DNS 服务器（如果启用）
if [[ "$(yaml_get '.global.enable_ipv6' config.yaml)" == "true" ]]; then
    dns_server_ipv6=$(yaml_get '.global.dns_server_ipv6' config.yaml)
    if [[ -n "$dns_server_ipv6" ]]; then
        echo "nameserver $dns_server_ipv6" >> /etc/resolv.conf
    fi
fi

echo "OK: DNS configuration completed"
```

### 4.6 step06_yum_server.sh
```bash
#!/bin/bash
# YUM 源服务器配置（基于 installscript/01.yum.sh）

yum_server_ip=$(yaml_get '.global.yum_server_ip' config.yaml)
packages_dir=$(yaml_get '.global.packages_dir' config.yaml)

# 1. 安装 HTTP 服务器
yum install -y httpd

# 2. 解压 YUM 源包
if [[ -d "${packages_dir}/06.repo" ]]; then
    tar -xzf "${packages_dir}/06.repo/kylinos.tar.gz" -C /var/www/html/
fi

# 3. 启动 HTTP 服务
systemctl enable httpd
systemctl start httpd

# 4. 创建客户端配置文件
cat > /tmp/yum_client.conf << EOF
[kylinos]
name=KylinOS Repository
baseurl=http://${yum_server_ip}/kylinos
gpgcheck=0
enabled=1
EOF

echo "OK: YUM server setup completed"
```

### 4.7 step07_yum_client.sh
```bash
#!/bin/bash
# YUM 源客户端配置（基于 installscript/01.yum_client.sh）

yum_server_ip=$(yaml_get '.global.yum_server_ip' config.yaml)

# 配置 YUM 客户端
cat > /etc/yum.repos.d/kylinos.repo << EOF
[kylinos]
name=KylinOS Repository
baseurl=http://${yum_server_ip}/kylinos
gpgcheck=0
enabled=1
EOF

# 清理 YUM 缓存
yum clean all
yum makecache

echo "OK: YUM client configuration completed"
```

### 4.8 step08_container_runtime.sh
```bash
#!/bin/bash
# 容器运行时安装（基于 02.docker_install.sh 或 02.contaired_install.sh）

k8s_version=$(yaml_get '.global.kubernetes_version' config.yaml)
packages_dir=$(yaml_get '.global.packages_dir' config.yaml)

if [[ "$k8s_version" == "1.23.17" ]]; then
    # 安装 Docker 20.10.24
    docker_package="${packages_dir}/01.rpm_package/docker/docker-20.10.24.tgz"

    # 解压 Docker
    tar -xzf "$docker_package" -C /usr/local/

    # 配置 Docker 服务
    cat > /etc/systemd/system/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

    # 配置 Docker daemon
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2",
    "registry-mirrors": ["http://$(yaml_get '.global.registry' config.yaml)"],
    "ipv6": true,
    "fixed-cidr-v6": "$(yaml_get '.global.ipv6_pod_network_cidr' config.yaml)"
}
EOF

    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker

else
    # 安装 containerd 1.7.18（K8s 1.30.14）
    containerd_package="${packages_dir}/02.container_runtime/containerd/containerd-1.7.18-linux-$(detect_arch).tar.gz"

    # 解压 containerd
    tar -xzf "$containerd_package" -C /usr/local/

    # 安装 runc
    cp "${packages_dir}/02.container_runtime/containerd/runc.$(detect_arch)" /usr/local/sbin/runc
    chmod +x /usr/local/sbin/runc

    # 配置 containerd
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # 修改配置以支持国内镜像
    sed -i 's|k8s.gcr.io|registry.cn-hangzhou.aliyuncs.com/google_containers|g' /etc/containerd/config.toml

    # 创建 systemd 服务文件
    cat > /etc/systemd/system/containerd.service << 'EOF'
[Unit]
Description=containerd Container Runtime
Documentation=https://containerd.io
After=network.target

[Service]
Type=notify
ExecStartPre=/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
KillMode=process
Delegate=yes
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable containerd
    systemctl start containerd

    # 配置 crictl
    cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
fi

echo "OK: Container runtime installation completed"
```

### 4.9 step09_registry_install.sh
```bash
#!/bin/bash
# 私有镜像仓库部署（基于 installscript/03.registry_install.sh）

local_ip=$(get_local_ip)
registry_user=$(yaml_get '.global.registry_user' config.yaml)
registry_pass=$(yaml_get '.global.registry_pass' config.yaml)
packages_dir=$(yaml_get '.global.packages_dir' config.yaml)

# 1. 加载 Registry 镜像
docker load -i "${packages_dir}/04.registry/registry/registry-2.7.1-$(detect_arch).tar"

# 2. 创建 Registry 数据目录
mkdir -p /data/registry

# 3. 创建认证配置（如果启用）
if [[ -n "$registry_user" ]]; then
    mkdir -p /data/registry/auth
    docker run --rm --entrypoint htpasswd registry:2.7.1 \
        -Bbn "$registry_user" "$registry_pass" > /data/registry/auth/htpasswd
fi

# 4. 创建 Registry 配置
echo "----正在解压镜像文件----"

tar -xzf registry-$2.tgz  -C /data
cd /data
mv registry registry_data

# 5. 启动 Registry 服务
docker run -d \
    --name registry \
    --restart=always \
    -p 5000:5000 \
    -v /data/registry:/var/lib/registry \
    -v /etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro \
    registry:2.7.1

# 6. （可选）启动 Registry UI
if [[ -f "${packages_dir}/04.registry/registry-ui-${arch}.tar" ]]; then
    docker load -i "${packages_dir}/04.registry/registry-ui-${arch}.tar"

    docker run -d \
        --name registry-ui \
        --restart=always \
        -p 8080:80 \
        -e REGISTRY_URL=http://$local_ip:5000 \
        -e DELETE_IMAGES=true \
        joxit/docker-registry-ui:static
fi

echo "OK: Registry installation completed"
```


### 4.10 step10_cluster_init.sh
```bash
#!/bin/bash
# Kubernetes 集群初始化（基于 installscript/05.init-Cluster.sh）

local_ip=$(get_local_ip)
k8s_version=$(yaml_get '.global.kubernetes_version' config.yaml)
pod_network_cidr=$(yaml_get '.global.pod_network_cidr' config.yaml)
service_subnet=$(yaml_get '.global.service_subnet' config.yaml)

# 1. 生成 kubeadm 配置文件
cat > /tmp/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$local_ip"
  bindPort: 6443
nodeRegistration:
#  criSocket: /var/run/cri-dockerd.sock
  imagePullPolicy: IfNotPresent
  taints: null
---
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager: {}
dns: {}
etcd:
  local:
    dataDir: /data/etcd_data #放在有足够空间的路径下
imageRepository: registry:5000/google_containers   #指定为前面安装registry的库，ex:1.1.1.1:5000/k8s
kind: ClusterConfiguration
kubernetesVersion: v${k8s_version}
controlPlaneEndpoint: "k8sc1:6443"  #开启该选项，以便后期升级为高可用集群
networking:
  dnsDomain: cluster.local
  podSubnet: 10.42.0.0/16
  serviceSubnet: 10.96.0.0/12
scheduler: {}

EOF
```


双栈网络：
cluster-DualStack.yaml

```bash
cat > /tmp/kubeadm-config-DualStack.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
  groups:
  - system:bootstrappers:kubeadm:default-node-token

localAPIEndpoint:
  advertiseAddress: "$local_ip"   # 控制平面监听 IPv4 地址
  bindPort: 6443

nodeRegistration:
  imagePullPolicy: IfNotPresent
  criSocket: unix:///var/run/containerd/containerd.sock
  taints: null
  kubeletExtraArgs:
    # node-ip 必须是 IPv4 + 可达 IPv6 (不能是 link-local fe80)
    node-ip: "192.168.62.171,fd00:42::171"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration

kubernetesVersion: v${k8s_version}
clusterName: kubernetes
certificatesDir: /etc/kubernetes/pki

controlPlaneEndpoint: "k8sc1:6443"   # 高可用入口

imageRepository: registry:5000/google_containers

networking:
  podSubnet: "10.244.0.0/16,fd10:244::/56"       # IPv4 + IPv6 Pod 网络
  serviceSubnet: "10.96.0.0/16,fd10:96::/112" # IPv4 + IPv6 Service 网络
  dnsDomain: cluster.local

apiServer:
  timeoutForControlPlane: 4m0s

controllerManager:
  extraArgs:
    # cluster-cidr: v4,v6（controller-manager 用于节点CIDR分配/校验）
    cluster-cidr: "10.244.0.0/16,fd10:244::/56"
    node-cidr-mask-size-ipv4: "24"
    node-cidr-mask-size-ipv6: "64"
scheduler: {}
dns: {}
etcd:
  local:
    dataDir: /data/etcd_data   # 确保有足够空间
EOF
```



# 2. 初始化集群
kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs

# 3. 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 4. 配置 kube-controller-manager 证书有效期（99年）

使用yq，再

# 5. 验证集群状态
kubectl get nodes
kubectl get pods -A

echo "OK: Cluster initialization completed"
```

### 4.11 step11_admin_conf.sh
```bash
#!/bin/bash
# kubectl 配置（基于 installscript/06.set-admin-conf.sh）

# 1. 创建 kubectl 目录
mkdir -p /root/.kube

# 2. 复制配置文件
cp /etc/kubernetes/admin.conf /root/.kube/config

# 3. 设置权限
chown root:root /root/.kube/config

# 4. 添加 bash 自动补全
kubectl completion bash > /etc/bash_completion.d/kubectl
echo 'source <(kubectl completion bash)' >> /root/.bashrc

# 5. 设置别名
echo 'alias k=kubectl' >> /root/.bashrc
echo 'complete -F __start_kubectl k' >> /root/.bashrc

echo "OK: kubectl configuration completed"
```

### 4.12 step12_join_controlplane.sh
```bash
#!/bin/bash
# 添加控制平面节点（待扩展）

control_plane_hosts=$(get_hosts_by_role control-plane)
join_command=$(get_join_command control-plane)

for host in $control_plane_hosts; do
    if [[ "$host" != "$(hostname)" ]]; then
        # 分发 join 脚本
        echo "$join_command" > /tmp/join_controlplane.sh
        scp_send $host /tmp/join_controlplane.sh /tmp/

        # 执行 join
        remote_exec $host "bash /tmp/join_controlplane.sh"
    fi
done

echo "OK: Control plane nodes joined"
```

### 4.13 step13_join_worker.sh
```bash
#!/bin/bash
# 添加工作节点（待扩展）

worker_hosts=$(get_hosts_by_role worker)
join_command=$(get_join_command worker)

for host in $worker_hosts; do
    # 分发 join 脚本
    echo "$join_command" > /tmp/join_worker.sh
    scp_send $host /tmp/join_worker.sh /tmp/

    # 执行 join
    remote_exec $host "bash /tmp/join_worker.sh"
done

echo "OK: Worker nodes joined"
```

### 4.14 step14_cni_install.sh
```bash
#!/bin/bash
# CNI 插件安装（待扩展）

pod_network_cidr=$(yaml_get '.global.pod_network_cidr' config.yaml)

# 安装 Flannel
## ipv4 
if 
kubectl apply -f /data/k8s_install/03.setup_file/kube-flannel.yml

## 双栈网络
kubectl apply -f /data/k8s_install/03.setup_file/kube-DualStack.yml

echo "OK: CNI installation completed"
```

### 4.15 step15_nfs_config.sh
```bash
#!/bin/bash
# NFS 存储配置（基于 installscript/09.nfs_*.sh）

local_ip=$(get_local_ip)
nfs_path=$(yaml_get '.global.nfs_path' config.yaml)
nfs_server=$(yaml_get '.global.nfs_server' config.yaml)

if [[ "$local_ip" == "$nfs_server" ]]; then
    # NFS 服务器配置
    # 1. 安装 NFS 服务
    yum install -y nfs-utils

    # 2. 创建 NFS 共享目录
    mkdir -p $nfs_path
    chmod 755 $nfs_path

    # 3. 配置 exports
    echo "$nfs_path *(rw,sync,no_root_squash,no_subtree_check)" >> /etc/exports

    # 4. 启动 NFS 服务
    systemctl enable rpcbind
    systemctl enable nfs-server
    systemctl start rpcbind
    systemctl start nfs-server

    echo "OK: NFS server configuration completed"
else
    # NFS 客户端配置
    # 1. 安装 NFS 客户端
    yum install -y nfs-utils

    # 2. 创建挂载点
    mkdir -p $nfs_path

    # 3. 配置自动挂载
    echo "${nfs_server}:${nfs_path} ${nfs_path} nfs defaults,_netdev 0 0" >> /etc/fstab

    # 4. 执行挂载
    mount -a

    echo "OK: NFS client configuration completed"
fi
```

## 5. verify_*.sh 验证脚本

每个验证脚本检查特定步骤的完成状态，返回 OK/NOT_OK/ERROR。

### 5.1 verify01_root.sh
```bash
#!/bin/bash
# 验证 root 权限

if [[ $EUID -eq 0 ]]; then
    echo "OK"
else
    echo "NOT_OK"
fi
```

### 5.2 verify02_ssh.sh
```bash
#!/bin/bash
# 验证 SSH 免密登录

ssh_ok=true
for host in $(get_all_hosts); do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$host" "echo OK" >/dev/null 2>&1; then
        ssh_ok=false
        break
    fi
done

if $ssh_ok; then
    echo "OK"
else
    echo "NOT_OK"
fi
```

### 5.3 verify03_env.sh
```bash
#!/bin/bash
# 验证系统环境配置

# 1. 检查 swap 是否关闭
if [[ $(swapon --show | wc -l) -ne 0 ]]; then
    echo "NOT_OK: Swap is still enabled"
    exit 1
fi

# 2. 检查防火墙状态
if systemctl is-active firewalld >/dev/null 2>&1; then
    echo "NOT_OK: Firewall is still active"
    exit 1
fi

# 3. 检查内核模块
if ! lsmod | grep -q overlay; then
    echo "NOT_OK: overlay module not loaded"
    exit 1
fi

if ! lsmod | grep -q br_netfilter; then
    echo "NOT_OK: br_netfilter module not loaded"
    exit 1
fi

# 4. 检查 sysctl 参数
if [[ $(sysctl -n net.ipv4.ip_forward) != "1" ]]; then
    echo "NOT_OK: IPv4 forwarding not enabled"
    exit 1
fi

if [[ $(sysctl -n net.ipv6.conf.all.forwarding) != "1" ]]; then
    echo "NOT_OK: IPv6 forwarding not enabled"
    exit 1
fi

if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) != "0" ]]; then
    echo "NOT_OK: IPv6 is disabled"
    exit 1
fi

# 5. 检查 IPv6 网卡配置
local_ipv6=$(yaml_get ".nodes[] | select(.id == \"$(hostname)\") | .ipv6" config.yaml)
if [[ -n "$local_ipv6" ]]; then
    primary_interface=$(ip route | grep default | awk '{print $5}' | head -n1)

    if ! ip -6 addr show dev "$primary_interface" 2>/dev/null | grep -q "$local_ipv6"; then
        echo "NOT_OK: IPv6 address $local_ipv6 not configured on interface $primary_interface"
        exit 1
    fi

    # 检查 IPv6 连通性
    if ! ping6 -c 1 -W 3 "$local_ipv6" >/dev/null 2>&1; then
        echo "NOT_OK: IPv6 address $local_ipv6 not reachable"
        exit 1
    fi
fi

echo "OK"
```

### 5.4 verify04_dns.sh
```bash
#!/bin/bash
# 验证 DNS 配置

dns_server=$(yaml_get '.global.dns_server' config.yaml)

if grep -q "nameserver $dns_server" /etc/resolv.conf; then
    echo "OK"
else
    echo "NOT_OK: DNS server not configured"
fi
```

### 5.5 verify05_yum.sh
```bash
#!/bin/bash
# 验证 YUM 源配置

if yum repolist | grep -q kylinos; then
    echo "OK"
else
    echo "NOT_OK: YUM repository not configured"
fi
```

### 5.6 verify06_container_runtime.sh
```bash
#!/bin/bash
# 验证容器运行时

k8s_version=$(yaml_get '.global.kubernetes_version' config.yaml)

if [[ "$k8s_version" == "1.23.17" ]]; then
    # 验证 Docker
    if systemctl is-active docker >/dev/null 2>&1 && \
       docker info >/dev/null 2>&1; then
        echo "OK"
    else
        echo "NOT_OK: Docker not running properly"
    fi
else
    # 验证 containerd
    if systemctl is-active containerd >/dev/null 2>&1 && \
       ctr version >/dev/null 2>&1; then
        echo "OK"
    else
        echo "NOT_OK: containerd not running properly"
    fi
fi
```

### 5.7 verify07_registry.sh
```bash
#!/bin/bash
# 验证镜像仓库

registry_host=$(yaml_get '.global.registry_host' config.yaml)
registry_port=$(yaml_get '.global.registry_port' config.yaml)

if curl -f http://${registry_host}:${registry_port}/v2/_catalog >/dev/null 2>&1; then
    echo "OK"
else
    echo "NOT_OK: Registry not accessible"
fi
```

### 5.8 verify08_k8s_components.sh
```bash
#!/bin/bash
# 验证 Kubernetes 组件安装

# 检查 kubeadm
if ! command -v kubeadm >/dev/null 2>&1; then
    echo "NOT_OK: kubeadm not installed"
    exit 1
fi

# 检查 kubelet
if ! command -v kubelet >/dev/null 2>&1; then
    echo "NOT_OK: kubelet not installed"
    exit 1
fi

# 检查 kubectl
if ! command -v kubectl >/dev/null 2>&1; then
    echo "NOT_OK: kubectl not installed"
    exit 1
fi

# 检查 kubelet 服务
if ! systemctl is-enabled kubelet >/dev/null 2>&1; then
    echo "NOT_OK: kubelet service not enabled"
    exit 1
fi

echo "OK"
```

### 5.9 verify09_cluster.sh
```bash
#!/bin/bash
# 验证集群状态

if [[ ! -f $HOME/.kube/config ]]; then
    echo "NOT_OK: kubectl config not found"
    exit 1
fi

# 检查 API 服务器连接
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "NOT_OK: Cannot connect to API server"
    exit 1
fi

# 检查系统 Pod 状态
not_ready_pods=$(kubectl get pods -n kube-system --no-headers | grep -v "Running\|Completed" | wc -l)
if [[ $not_ready_pods -gt 0 ]]; then
    echo "NOT_OK: Some system pods are not ready"
    exit 1
fi

echo "OK"
```

### 5.10 verify10_admin_conf.sh
```bash
#!/bin/bash
# 验证 kubectl 配置

if [[ -f $HOME/.kube/config ]] && \
   kubectl cluster-info >/dev/null 2>&1; then
    echo "OK"
else
    echo "NOT_OK: kubectl not configured properly"
fi
```

### 5.11 verify11_join_controlplane.sh
```bash
#!/bin/bash
# 验证控制平面节点加入

expected_control_planes=$(get_hosts_by_role control-plane | wc -l)
actual_control_planes=$(kubectl get nodes --no-headers | grep "control-plane\|master" | wc -l)

if [[ $expected_control_planes -eq $actual_control_planes ]]; then
    echo "OK"
else
    echo "NOT_OK: Control plane nodes not fully joined"
fi
```

### 5.12 verify12_join_worker.sh
```bash
#!/bin/bash
# 验证工作节点加入

expected_workers=$(get_hosts_by_role worker | wc -l)
actual_workers=$(kubectl get nodes --no-headers | grep -v "control-plane\|master" | wc -l)

if [[ $expected_workers -eq $actual_workers ]]; then
    echo "OK"
else
    echo "NOT_OK: Worker nodes not fully joined"
fi
```

### 5.13 verify13_cni.sh
```bash
#!/bin/bash
# 验证 CNI 安装

pod_network_cidr=$(yaml_get '.global.pod_network_cidr' config.yaml)

# 检查 Flannel Pod
flannel_pods=$(kubectl get pods -n kube-flannel --no-headers | grep "Running" | wc -l)
if [[ $flannel_pods -eq 0 ]]; then
    echo "NOT_OK: Flannel pods not running"
    exit 1
fi

# 检查 CoreDNS
coredns_pods=$(kubectl get pods -n kube-system --no-headers | grep "coredns" | grep "Running" | wc -l)
if [[ $coredns_pods -eq 0 ]]; then
    echo "NOT_OK: CoreDNS pods not running"
    exit 1
fi

echo "OK"
```

### 5.14 verify14_nfs.sh
```bash
#!/bin/bash
# 验证 NFS 配置

nfs_server=$(yaml_get '.global.nfs_server' config.yaml)
nfs_path=$(yaml_get '.global.nfs_path' config.yaml)

if [[ "$(hostname -I | awk '{print $1}')" == "$nfs_server" ]]; then
    # 验证 NFS 服务器
    if systemctl is-active nfs-server >/dev/null 2>&1 && \
       exportfs -v | grep -q "$nfs_path"; then
        echo "OK"
    else
        echo "NOT_OK: NFS server not configured properly"
    fi
else
    # 验证 NFS 客户端
    if findmnt -n "$nfs_path" | grep -q "$nfs_server"; then
        echo "OK"
    else
        echo "NOT_OK: NFS client not mounted properly"
    fi
fi
```

### 5.15 verify15_certificates.sh
```bash
#!/bin/bash
# 验证证书有效期

# 检查 API 服务器证书
api_cert=$(kubectl get secrets kubernetes-root-ca-cert -n kube-system -o jsonpath='{.data.tls\.crt}' | base64 -d)
api_cert_expiry=$(echo "$api_cert" | openssl x509 -noout -enddate | cut -d= -f2)

# 检查 CA 证书
ca_cert=$(kubectl get configmap cluster-info -n kube-public -o jsonpath='{.data.kubeconfig}' | grep certificate-authority-data | awk '{print $2}' | base64 -d)
ca_cert_expiry=$(echo "$ca_cert" | openssl x509 -noout -enddate | cut -d= -f2)

# 验证证书有效期（应该接近 99 年）
if [[ "$api_cert_expiry" =~ "2122" ]] && [[ "$ca_cert_expiry" =~ "2122" ]]; then
    echo "OK"
else
    echo "NOT_OK: Certificates not configured for 99-year validity"
fi
```

## 6. config.yaml 配置文件

config.yaml 是整个系统的驱动配置文件，包含所有必要的参数。

### 6.1 完整配置示例

```yaml
# 节点配置
nodes:
  - id: k8s-master01
    ip: 192.168.62.171
    ipv6: "fd00:42::171"            # 可选
    ssh_user: root
    ssh_pass: Kylin123123        # 建议使用密钥而非密码
    roles: [control-plane, etcd]
    labels: {zone: az1, node-type: master}
    pre_tasks: [check_disk, check_memory]
    post_tasks: [report_status]

  - id: k8s-master02
    ip: 192.168.62.172
    ipv6: "fd00:42::172"            # IPv6 地址
    ssh_user: root
    ssh_pass: Kylin123123
    roles: [control-plane, etcd]
    labels: {zone: az1, node-type: master}

  - id: k8s-master03
    ip: 192.168.62.173
    ipv6: "fd00:42::173"            # IPv6 地址
    ssh_user: root
    ssh_pass: Kylin123123
    roles: [control-plane, etcd]
    labels: {zone: az1, node-type: master}

  - id: k8s-worker01
    ip: 192.168.62.174
    ipv6: "fd00:42::174"            # IPv6 地址
    ssh_user: root
    ssh_pass: Kylin123123
    roles: [worker]
    labels: {zone: az1, node-type: worker}

  - id: k8s-worker02
    ip: 192.168.62.175
    ipv6: "fd00:42::175"            # IPv6 地址
    ssh_user: root
    ssh_pass: Kylin123123
    roles: [worker]
    labels: {zone: az1, node-type: worker}

# 全局配置
global:
  # 基础配置
  packages_dir: "/data/k8s_install"
  arch: "amd64"                  # amd64 或 arm64
  concurrency: 8
  verify_timeout: 30

  # Kubernetes 配置
  kubernetes_version: "1.23.17"   # 支持 1.23.17 或 1.30.14
  pod_network_cidr: "10.244.0.0/16"
  service_subnet: "10.96.0.0/12"

  # IPv6 网络配置
  enable_ipv6: true              # 启用 IPv6 支持
  ipv6_pod_network_cidr: "fd10:244::/56"  # IPv6 Pod 网络
  ipv6_service_subnet: "fd10:96::/112"     # IPv6 Service 网络
  ipv6_default_gateway: "fd00::1"             # IPv6 默认网关

  # 网络配置
  dns_server: "114.114.114.114"
  dns_server_ipv6: "fd00:42::1"      # IPv6 DNS 服务器
  yum_server_ip: "192.168.62.171"

  # 镜像仓库配置
  registry_host: "192.168.62.171"
  registry_port: 5000
  registry_user: "admin"
  registry_pass: "admin123"
  registry_insecure: false

  # NFS 配置
  nfs_server: "192.168.62.171"
  nfs_path: "/data/nfs"

  # 日志配置
  log_dir: "/data/k8s_install/logs"
  log_level: "INFO"
  log_rotation: "daily"
  log_max_files: 30

  # 状态目录
  status_dir: "/data/k8s_install/status"

  # 离线模式
  offline_mode: true

  # 重试配置
  max_retries: 3
  retry_interval: 5

# 模块配置
modules:
  # 核心组件
  enable_ssh_key: true
  enable_env_prepare: true
  enable_dns_config: true
  enable_yum_server: true
  enable_yum_client: true
  enable_container_runtime: true
  enable_registry: true
  enable_k8s_install: true
  enable_cluster_init: true
  enable_admin_conf: true

  # 可选组件
  enable_controlplane_join: true
  enable_worker_join: true
  enable_cni: true
  enable_nfs: false

  # 高级组件
  enable_helm: false
  enable_prometheus: false
  enable_grafana: false
  enable_elasticsearch: false
  enable_ingress: false

  # 备份和监控
  enable_etcd_backup: false
  enable_metrics_server: false

# 步骤执行配置
steps:
  - name: check_root
    enabled: true
    mode: serial        # serial 或 parallel
    timeout: 60
    retry: 0
    verify: true

  - name: ssh_key
    enabled: true
    mode: serial
    timeout: 300
    retry: 2
    verify: true
    dependencies: [check_root]

  - name: env_prepare
    enabled: true
    mode: parallel
    timeout: 180
    retry: 1
    verify: true
    dependencies: [ssh_key]

  - name: dns_config
    enabled: true
    mode: parallel
    timeout: 60
    retry: 1
    verify: true
    dependencies: [env_prepare]

  - name: yum_server
    enabled: true
    mode: serial
    hosts: ["k8s-master01"]  # 只在主节点执行
    timeout: 300
    retry: 1
    verify: true
    dependencies: [dns_config]

  - name: yum_client
    enabled: true
    mode: parallel
    hosts: ["k8s-master02", "k8s-master03", "k8s-worker01", "k8s-worker02"]
    timeout: 120
    retry: 1
    verify: true
    dependencies: [yum_server]

  - name: container_runtime
    enabled: true
    mode: parallel
    timeout: 300
    retry: 2
    verify: true
    dependencies: [yum_client]

  - name: registry
    enabled: true
    mode: serial
    hosts: ["k8s-master01"]
    timeout: 180
    retry: 1
    verify: true
    dependencies: [container_runtime]

  - name: k8s_install
    enabled: true
    mode: parallel
    timeout: 600
    retry: 2
    verify: true
    dependencies: [registry]

  - name: cluster_init
    enabled: true
    mode: serial
    hosts: ["k8s-master01"]
    timeout: 600
    retry: 0  # 集群初始化不重试
    verify: true
    dependencies: [k8s_install]

  - name: controlplane_join
    enabled: true
    mode: serial
    hosts: ["k8s-master02", "k8s-master03"]
    timeout: 600
    retry: 1
    verify: true
    dependencies: [cluster_init]

  - name: worker_join
    enabled: true
    mode: parallel
    hosts: ["k8s-worker01", "k8s-worker02"]
    timeout: 300
    retry: 1
    verify: true
    dependencies: [controlplane_join]

  - name: cni
    enabled: true
    mode: serial
    hosts: ["k8s-master01"]
    timeout: 300
    retry: 1
    verify: true
    dependencies: [worker_join]

  - name: admin_conf
    enabled: true
    mode: parallel
    timeout: 60
    retry: 0
    verify: true
    dependencies: [cluster_init]

  - name: nfs
    enabled: false
    mode: parallel
    timeout: 180
    retry: 1
    verify: true
    dependencies: [cni]

# 证书配置
certificates:
  # 证书有效期配置
  api_server_duration: "87600h"    # 10 年
  ca_duration: "876000h"           # 100 年

  # 自动轮换
  enable_auto_renewal: true
  renewal_threshold: "720h"        # 30 天前开始轮换

  # 备份
  backup_certificates: true
  backup_dir: "/data/k8s_install/certs/backup"

# 网络策略
network_policies:
  # 默认策略
  default_deny: false
  allow_dns: true

  # Pod 网络
  pod_network_cidr: "10.244.0.0/16"
  service_subnet: "10.96.0.0/12"

  # 网络插件
  cni_plugin: "flannel"
  flannel_version: "v0.20.2"

# 存储配置
storage:
  # 本地存储
  local_storage_class: "local-storage"
  local_storage_path: "/data/k8s-storage"

  # NFS 存储
  nfs_storage_class: "nfs-storage"
  nfs_server: "192.168.62.171"
  nfs_path: "/data/nfs"

  # 持久卷声明
  default_pvc_size: "10Gi"
  max_pvc_size: "100Gi"

# 安全配置
security:
  # Pod 安全策略
  pod_security_policy: false
  privileged_pods: false

  # RBAC
  enable_rbac: true
  default_role: "view"

  # 网络安全
  network_policy: false
  iptables_rules: true

# 监控配置
monitoring:
  # 指标收集
  metrics_server: false
  prometheus: false
  grafana: false

  # 日志收集
  elasticsearch: false
  kibana: false
  fluentd: false

  # 告警
  alertmanager: false

# 备份配置
backup:
  # ETCD 备份
  etcd_backup: false
  etcd_backup_interval: "6h"
  etcd_backup_retention: "7d"
  etcd_backup_dir: "/data/k8s_install/backup/etcd"

  # 应用备份
  application_backup: false
  backup_schedule: "0 2 * * *"
  backup_retention: "30d"
  backup_dir: "/data/k8s_install/backup/applications"
```

### 6.2 配置项说明

#### 6.2.1 节点配置
- **id**: 节点唯一标识符
- **ip**: 节点 IP 地址
- **ipv6**: 可选的 IPv6 地址
- **ssh_user**: SSH 用户名
- **ssh_pass**: SSH 密码（建议使用密钥）
- **roles**: 节点角色列表（control-plane, etcd, worker）
- **labels**: 节点标签
- **pre_tasks**: 节点前置任务
- **post_tasks**: 节点后置任务

#### 6.2.2 全局配置
- **packages_dir**: 离线安装包目录
- **arch**: 系统架构（amd64 或 arm64）
- **concurrency**: 并发执行数
- **kubernetes_version**: K8s 版本
- **pod_network_cidr**: IPv4 Pod 网络 CIDR
- **service_subnet**: IPv4 Service 网络 CIDR

##### IPv6 配置项
- **enable_ipv6**: 是否启用 IPv6 支持（true/false）
- **ipv6_pod_network_cidr**: IPv6 Pod 网络 CIDR（例如：fd10:244::/56）
- **ipv6_service_subnet**: IPv6 Service 网络 CIDR（例如：fd10:96::/112）
- **ipv6_default_gateway**: IPv6 默认网关（例如：fd00::1）
- **dns_server_ipv6**: IPv6 DNS 服务器（例如：fd00::1）

##### 网卡配置参数
每个节点的网卡配置支持以下参数：
- **IPV6INIT**: 启用 IPv6 初始化（yes/no）
- **IPV6_AUTOCONF**: 禁用 IPv6 自动配置（yes/no）
- **IPV6ADDR**: IPv6 地址（例如：fd00:42::176）
- **IPV6_DEFAULTGW**: IPv6 默认网关（例如：fd00::1）
- **IPV6_DEFROUTE**: 启用 IPv6 默认路由（yes/no）
- **IPV6_FAILURE_FATAL**: IPv6 配置失败时不中止（yes/no）

#### 6.2.3 模块配置
控制各功能模块的启用/禁用状态。

#### 6.2.4 步骤配置
- **enabled**: 是否启用该步骤
- **mode**: 执行模式（serial/parallel）
- **timeout**: 超时时间（秒）
- **retry**: 重试次数
- **verify**: 是否执行验证
- **dependencies**: 依赖步骤
- **hosts**: 指定执行主机（可选）

## 7. 日志处理

### 7.1 日志目录结构

```
logs/
├── installer_20251115.log        # 主控脚本日志
├── installer_20251116.log        # 按日轮转的主日志
├── nodes/                        # 各节点日志
│   ├── k8s-master01.log
│   ├── k8s-master02.log
│   ├── k8s-worker01.log
│   └── k8s-worker02.log
├── steps/                        # 各步骤详细日志
│   ├── env_prepare/
│   │   ├── k8s-master01.log
│   │   └── k8s-master02.log
│   ├── k8s_install/
│   │   ├── k8s-master01.log
│   │   └── k8s-master02.log
│   └── ...
└── error/                        # 错误日志
    ├── step_errors.log
    └── node_errors.log
```

### 7.2 日志格式

所有日志采用统一格式：

```
2025-11-15T12:00:00+08:00 [INFO] [k8s-master01] [step:env_prepare] Environment preparation started
2025-11-15T12:01:30+08:00 [WARN] [k8s-master01] [step:env_prepare] Firewall service not found, skipping
2025-11-15T12:02:15+08:00 [ERROR] [k8s-worker01] [step:k8s_install] Package installation failed: dependency not found
2025-11-15T12:02:20+08:00 [FATAL] [installer] [step:cluster_init] Cluster initialization failed, aborting
```

### 7.3 日志级别

- **DEBUG**: 调试信息，详细的执行过程
- **INFO**: 一般信息，正常流程记录
- **WARN**: 警告信息，不影响执行但需要注意
- **ERROR**: 错误信息，步骤执行失败但可恢复
- **FATAL**: 致命错误，导致整个安装流程中止

### 7.4 日志轮转和清理

```bash
# 日志轮转策略
rotate_logs() {
    local max_size=${1:-100M}      # 单个日志文件最大大小
    local max_files=${2:-30}       # 保留的日志文件数量
    local rotation_interval=${3:-daily}  # 轮转间隔

    case $rotation_interval in
        daily)
            # 按天轮转
            find "$LOG_DIR" -name "*.log" -daystart -mtime +1 -exec gzip {} \;
            find "$LOG_DIR" -name "*.log.gz" -daystart -mtime +$max_files -delete
            ;;
        size)
            # 按大小轮转
            find "$LOG_DIR" -name "*.log" -size "+$max_size" -exec gzip {} \;
            find "$LOG_DIR" -name "*.log.gz" -mtime +$max_files -delete
            ;;
        *)
            echo "Unknown rotation interval: $rotation_interval"
            ;;
    esac
}

# 自动清理旧日志
cleanup_old_logs() {
    local days=${1:-7}             # 保留天数
    find "$LOG_DIR" -name "*.log" -o -name "*.log.gz" | while read log; do
        if [[ $(find "$log" -mtime +$days -print) ]]; then
            rm -f "$log"
        fi
    done
}
```

### 7.5 日志收集和分发

```bash
# 收集远程节点日志
collect_remote_logs() {
    local host=$1
    local remote_log_dir="/tmp/k8e_logs"

    # 在远程节点创建日志目录
    remote_exec $host "mkdir -p $remote_log_dir"

    # 收集系统日志
    remote_exec $host "journalctl --no-pager -u kubelet > $remote_log_dir/kubelet.log"
    remote_exec $host "journalctl --no-pager -u docker > $remote_log_dir/docker.log"
    remote_exec $host "journalctl --no-pager -u containerd > $remote_log_dir/containerd.log"

    # 收集 K8s 组件日志
    remote_exec $host "docker ps | grep kube- | awk '{print \$1}' | xargs -I{} docker logs {} > $remote_log_dir/kube-components.log"

    # 打包并传输回主节点
    remote_exec $host "cd $remote_log_dir && tar -czf /tmp/k8e_logs_${host}.tar.gz *"
    scp_send $host /tmp/k8e_logs_${host}.tar.gz "${LOG_DIR}/nodes/"

    # 解压到对应目录
    mkdir -p "${LOG_DIR}/nodes/${host}"
    tar -xzf "${LOG_DIR}/nodes/k8e_logs_${host}.tar.gz" -C "${LOG_DIR}/nodes/${host}/"

    # 清理临时文件
    remote_exec $host "rm -rf $remote_log_dir /tmp/k8e_logs_${host}.tar.gz"
}

# 实时日志监控
monitor_logs() {
    local host=${1:-""}
    local step=${2:-""}
    local follow=${3:-false}

    local log_pattern="${LOG_DIR}/installer_*.log"

    if [[ -n "$host" ]]; then
        log_pattern="${LOG_DIR}/nodes/${host}.log"
    fi

    if [[ -n "$step" ]]; then
        log_pattern="${LOG_DIR}/steps/${step}/*.log"
    fi

    if $follow; then
        tail -f $log_pattern
    else
        cat $log_pattern
    fi
}
```

## 8. 目录结构

### 8.1 完整目录结构

```
k8s_installer/                   # 项目根目录
├── installer.sh                 # 主控脚本
├── tools.sh                     # 通用工具库
├── config.yaml                  # 配置文件
├── config.json                  # JSON 格式配置文件（可选）
├── README.md                    # 项目说明文档
├── CHANGELOG.md                 # 变更日志
│
├── installscript/               # 现有安装脚本集合
│   ├── 0.ssh_nopasswd.sh        # SSH免密登录
│   ├── 01.set-env.sh            # 系统环境准备
│   ├── 01.dns.sh                # DNS配置
│   ├── 01.yum.sh                # YUM源服务器
│   ├── 01.yum_client.sh         # YUM源客户端
│   ├── 02.docker_install.sh     # Docker安装
│   ├── 02.contaired_install.sh  # containerd安装
│   ├── 03.registry_install.sh   # 镜像仓库安装
│   ├── 04.Dependency-Package-yum.sh    # K8s依赖安装（YUM方式）
│   ├── 04.Dependency-Package-rpm.sh    # K8s依赖安装（RPM方式）
│   ├── 05.init-Cluster.sh       # 集群初始化
│   ├── 06.set-admin-conf.sh     # kubectl配置
│   ├── 09.nfs_server.sh         # NFS服务器
│   ├── 09.nfs_mount.sh          # NFS客户端
│   └── generate_hosts.sh        # 主机名映射生成
│
├── steps/                       # 标准化步骤脚本
│   ├── step01_check_root.sh
│   ├── step02_ssh_key.sh
│   ├── step03_env_prepare.sh
│   ├── step04_dns_config.sh
│   ├── step05_yum_server.sh
│   ├── step06_yum_client.sh
│   ├── step07_container_runtime.sh
│   ├── step08_registry_install.sh
│   ├── step09_k8s_install.sh
│   ├── step10_cluster_init.sh
│   ├── step11_admin_conf.sh
│   ├── step12_join_controlplane.sh
│   ├── step13_join_worker.sh
│   ├── step14_cni_install.sh
│   └── step15_nfs_config.sh
│
├── verify/                      # 验证脚本
│   ├── verify01_root.sh
│   ├── verify02_ssh.sh
│   ├── verify03_env.sh
│   ├── verify04_dns.sh
│   ├── verify05_yum.sh
│   ├── verify06_container_runtime.sh
│   ├── verify07_registry.sh
│   ├── verify08_k8s_components.sh
│   ├── verify09_cluster.sh
│   ├── verify10_admin_conf.sh
│   ├── verify11_join_controlplane.sh
│   ├── verify12_join_worker.sh
│   ├── verify13_cni.sh
│   ├── verify14_nfs.sh
│   └── verify15_certificates.sh
│
├── templates/                   # 配置模板
│   ├── kubeadm-config.yaml.template
│   ├── flannel.yaml.template
│   ├── docker-daemon.json.template
│   ├── containerd-config.toml.template
│   └── nfs-provisioner.yaml.template
│
├── packages/                    # 离线安装包（用户上传）
│   ├── 01.rpm_package/          # RPM包
│   │   ├── k8s-1.23.17/
│   │   ├── k8s-1.30.14/
│   │   ├── system/
│   │   └── kubeadm100y-*/      # 99年证书支持
│   ├── 02.container_runtime/    # 容器运行时
│   │   ├── docker/
│   │   └── containerd/
│   ├── 03.setup_file/           # 配置文件
│   ├── 04.registry/             # 镜像仓库
│   ├── 05.harbor/               # Harbor仓库
│   ├── 06.crontab/              # 定时任务
│   ├── 07.helm/                 # Helm包
│   └── 07.tools/                # 工具二进制
│
├── logs/                        # 日志目录
│   ├── installer_20251115.log
│   ├── nodes/
│   ├── steps/
│   └── error/
│
├── status/                      # 状态文件目录
│   ├── k8s-master01_cluster_init.json
│   ├── k8s-master01_k8s_install.json
│   ├── k8s-worker01_env_prepare.json
│   └── ...
│
├── scripts/                     # 辅助脚本
│   ├── generate_config.sh       # 生成配置文件
│   ├── validate_config.sh       # 验证配置文件
│   ├── backup_cluster.sh        # 集群备份
│   ├── restore_cluster.sh       # 集群恢复
│   └── cleanup.sh               # 清理脚本
│
├── docs/                        # 文档目录
│   ├── installation-guide.md    # 安装指南
│   ├── configuration.md         # 配置说明
│   ├── troubleshooting.md       # 故障排除
│   └── api-reference.md         # API 参考
│
└── tests/                       # 测试脚本
    ├── unit_tests/              # 单元测试
    ├── integration_tests/       # 集成测试
    └── test_data/               # 测试数据
```

### 8.2 安装包目录结构

```
packages/                        # 由 global.packages_dir 配置
├── amd64/                       # x86_64 架构
│   ├── 01.rpm_package/
│   │   ├── k8s-1.23.17/
│   │   │   ├── kubeadm-1.23.17-0.x86_64.rpm
│   │   │   ├── kubelet-1.23.17-0.x86_64.rpm
│   │   │   ├── kubectl-1.23.17-0.x86_64.rpm
│   │   │   └── kubernetes-cni-1.2.0-0.x86_64.rpm
│   │   ├── k8s-1.30.14/
│   │   └── system/
│   ├── 02.container_runtime/
│   │   ├── docker/docker-20.10.24.tgz
│   │   └── containerd/
│   ├── 03.setup_file/
│   ├── 04.registry/
│   ├── 05.harbor/
│   ├── 06.crontab/
│   ├── 07.helm/
│   └── 07.tools/
└── arm64/                       # ARM64 架构
    └── [类似结构]
```

## 总结

本文档详细说明了 KubeEasy 项目的各个组件：

1. **installer.sh**: 主控脚本，负责整个安装流程的控制和管理
2. **tools.sh**: 通用工具库，提供日志、远程执行、并发控制等功能
3. **step_*.sh**: 标准化的安装步骤脚本，每个对应一个具体的安装任务
4. **verify_*.sh**: 验证脚本，用于检查各步骤的完成状态
5. **config.yaml**: 配置文件，驱动整个安装流程
6. **日志系统**: 完整的日志收集、轮转和监控机制

整个系统设计注重：
- **可配置性**: 通过配置文件控制所有行为
- **可重入性**: 支持中断后继续执行
- **并发控制**: 智能的并行/串行任务调度
- **状态管理**: 完整的安装状态跟踪
- **错误处理**: 健壮的错误处理和重试机制
- **离线部署**: 完全不依赖外网的安装方式

这个框架为 Kubernetes 集群的离线自动化部署提供了完整的解决方案。

## 9. IPv6 网络配置详细说明

### 9.1 IPv6 支持特性

KubeEasy 完全支持 IPv6 双栈网络部署，提供以下特性：

- **IPv6 地址自动配置**: 根据配置文件自动配置节点 IPv6 地址
- **IPv6 网络参数优化**: 自动配置 sysctl 参数以支持 IPv6 转发
- **IPv6 DNS 配置**: 支持 IPv6 DNS 服务器配置
- **IPv6 连通性验证**: 自动验证 IPv6 网络连通性
- **双栈网络支持**: 同时支持 IPv4 和 IPv6 网络配置

### 9.2 IPv6 配置流程

#### 9.2.1 系统级配置
```bash
# 1. 启用 IPv6 转发
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.default.disable_ipv6=0
sysctl -w net.ipv6.conf.lo.disable_ipv6=0

# 2. 配置网卡 IPv6 地址
# 自动生成 /etc/sysconfig/network-scripts/ifcfg-eth0 配置
IPV6INIT=yes
IPV6_AUTOCONF=no
IPV6ADDR=fd00:42::176
IPV6_DEFAULTGW=fd00::1
IPV6_DEFROUTE=yes
IPV6_FAILURE_FATAL=no

# 3. 重启网络服务
systemctl restart network
```

#### 9.2.2 Kubernetes IPv6 配置
```bash
# 1. 生成 kubeadm 配置支持双栈
cat > kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: "10.244.0.0/16,fd10:244::/56"
  serviceSubnet: "10.96.0.0/12,fd10:96::/112"
EOF

# 2. 初始化集群
kubeadm init --config=kubeadm-config.yaml
```

### 9.3 IPv6 配置最佳实践

#### 9.3.1 网络规划
- **节点 IPv6 地址**: 使用 fd00::/64 前缀的连续地址
- **Pod IPv6 网络**: 使用 fd10:244::/56，避免与节点地址冲突
- **Service IPv6 网络**: 使用 fd10:96::/112，提供足够的地址空间
- **默认网关**: 使用 fd00::1 作为 IPv6 网关

#### 9.3.2 配置验证
```bash
# 验证 IPv6 地址配置
ip -6 addr show

# 验证 IPv6 转发
sysctl net.ipv6.conf.all.forwarding

# 验证 IPv6 连通性
ping6 -c 3 fd00::1

# 验证 Pod IPv6 连通性
kubectl exec -it <pod> -- ping6 -c 3 fd00::1
```

### 9.4 IPv6 故障排除

#### 9.4.1 常见问题
1. **IPv6 地址未配置**: 检查网卡配置文件中的 IPV6ADDR 设置
2. **IPv6 转发未启用**: 确认 sysctl 参数正确配置
3. **IPv6 连通性问题**: 检查防火墙和路由配置
4. **Kubernetes Pod 无法访问 IPv6**: 检查 CNI 插件 IPv6 支持

#### 9.4.2 排查命令
```bash
# 检查 IPv6 路由
ip -6 route

# 检查 IPv6 邻居表
ip -6 neigh

# 检查 IPv6 防火墙规则
ip6tables -L -n

# 检查系统 IPv6 状态
cat /proc/sys/net/ipv6/conf/all/forwarding
```

### 9.5 IPv6 配置示例

完整的 IPv6 双栈配置示例：

```yaml
nodes:
  - id: k8s-master01
    ip: 192.168.62.171
    ipv6: "fd00:42::171"
    ssh_user: root
    roles: [control-plane, etcd]

global:
  enable_ipv6: true
  pod_network_cidr: "10.244.0.0/16"
  service_subnet: "10.96.0.0/12"
  ipv6_pod_network_cidr: "fd10:244::/56"
  ipv6_service_subnet: "fd10:96::/112"
  ipv6_default_gateway: "fd00::1"
  dns_server_ipv6: "fd00::1"

network_policies:
  enable_ipv6: true
  ipv6_cidr: "fd10:244::/56"
  ipv6_service_cidr: "fd10:96::/112"
```