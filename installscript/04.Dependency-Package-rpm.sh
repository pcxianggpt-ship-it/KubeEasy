#!/bin/bash

# Function to check and install Kylinos specific RPM packages with dependency detection
check_and_install_system_packages() {

    os_info=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2 | awk '{print $1}')

    local os_path="/tmp/k8s/rpm/system/$os_info"

    if [ ! -d "$os_path" ]; then
        echo "【WARN】: Kylinos RPM 目录不存在: $os_path"
        return 0
    fi


    # Finally install the target packages
    echo "正在安装目标包..."
    if rpm -ivh *.rpm > /dev/null 2>&1; then
        echo "【SUCCESS】: socat 和 conntrack-tools 安装成功"
        return 0
    else
        echo "【ERROR】: 目标包安装失败"
        return 1
    fi
}

# 检查system依赖包是否安装
if ! check_and_install_system_packages; then
    echo "【ERROR】: Kylinos RPM 包检查/安装失败，退出安装"
    exit 1
fi

# Function to verify package installation
verify_package() {
    local package_name="$1"
    if rpm -qa | grep -q "^${package_name}-"; then
        echo "【SUCCESS】: ${package_name} 安装成功"
        return 0
    else
        echo "【ERROR】: ${package_name} 安装失败"
        return 1
    fi
}

# Function to verify service is enabled
verify_service_enabled() {
    local service_name="$1"
    systemctl enable "$service_name" > /dev/null 2>&1
    if systemctl list-unit-files -t service | grep "$service_name" | awk '{print $NF}' | grep -q "enabled"; then
        echo "【SUCCESS】: ${service_name} 已设置自启动"
        return 0
    else
        echo "【ERROR】: ${service_name} 未设置自启动，请检查"
        return 1
    fi
}

echo "正在安装kubernetes $1 依赖" 
cd /tmp/k8s/rpm/$1
rpm -ivh *.rpm

# Verify Kubernetes packages installation
echo "验证 Kubernetes 组件安装..."
packages=("cri-tools" "kubelet" "kubeadm" "kubectl" "kubernetes-cni" "nfs-server")
for package in "${packages[@]}"; do
    if ! verify_package "$package"; then
        exit 1
    fi
done

# Enable and verify services
echo "配置服务自启动..."
services=("kubelet" "systemd-resolved")
for service in "${services[@]}"; do
    if ! verify_service_enabled "$service"; then
        exit 1
    fi
done

echo "【SUCCESS】: 所有组件安装和配置完成！"