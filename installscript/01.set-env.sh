## 创建工作目录
mkdir -p $1/k8s_install


## 关闭swap

swapoff -a
if cat /proc/swaps | wc -l | grep -q "1"; then
    echo "【SUCCESS】：swap已经关闭"
else
    echo "【ERROR】：swap仍为开启状态，请检查swapoff是否执行！！！"
fi

sed -i '/swap/d' /etc/fstab
if [ -z $(cat /etc/fstab | grep swap) ]; then
    echo "【SUCCESS】：系统启动不自动挂载swap区"
else
    echo "【ERROR】：文件系统仍有挂载swap区的内容，请检查/etc/fstab！！！"
fi


## 关闭防火墙
systemctl stop firewalld > /dev/null 2>&1
if systemctl status firewalld | grep Active | grep inactive | wc -l | grep -q "1"; then
    echo "【SUCCESS】：防火墙已经关闭"
else
    echo "【ERROR】：防火墙仍为开启状态，请检查防火墙！！！"
fi

## 取消防火墙自启动
systemctl disable firewalld > /dev/null 2>&1
if systemctl status firewalld | grep disabled | wc -l | grep -q "1"; then
    echo "【SUCCESS】：防火墙已经关闭自启动"
else
    echo "【ERROR】：防火墙仍为自启动状态，请检查防火墙！！！"
fi


## 卸载podman等容器
if rpm -qa | grep podman | wc -l | grep -q "0"; then
    echo "【SUCCESS】：系统中不存在podman容器"
else
    yum remove podman -y > /dev/null
    if rpm -qa | grep podman | wc -l | grep -q "0"; then
        echo "【SUCCESS】：系统中存在podman容器，已删除"
    else
        echo "【ERROR】：系统中存在podman容器，请手动删除！！！"
    fi
fi

if rpm -qa | grep containerd | wc -l | grep -q "0"; then
    echo "【SUCCESS】：系统中不存在containerd容器"
else
    yum remove containerd -y
    if rpm -qa | grep podman | wc -l | grep -q "0"; then
        echo "【SUCCESS】：系统中存在containerd容器，已删除"
    else
        echo "【ERROR】：系统中存在containerd容器，请手动删除！！！"
    fi
fi


sed -i '/nameserver/d' /etc/resolv.conf
echo "8.8.8.8 nameserver" >> /etc/resolv.conf






## 转发ipv4 ipv6并让iptables看到桥接流量
cat << EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

if ls /etc/modules-load.d/k8s.conf | wc -l | grep -q "1" ; then
    echo "【SUCCESS】：转发ipv4并让iptables看到桥接流量"
else
    echo "【ERROR】：转发ipv4并让iptables看到桥接流量"
fi

##  修改sysctl.conf
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.bridge.bridge-nf-call-iptables/d' /etc/sysctl.conf
sed -i '/net.bridge.bridge-nf-call-ip6tables/d' /etc/sysctl.conf
echo net.bridge.bridge-nf-call-iptables=1 >> /etc/sysctl.conf
echo net.bridge.bridge-nf-call-ip6tables=1 >> /etc/sysctl.conf
echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf


## ipv6
sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.default.forwarding/d' /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=0 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=0 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=0 >> /etc/sysctl.conf
echo net.ipv6.conf.all.forwarding=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.forwarding=1 >> /etc/sysctl.conf


sysctl --system > /dev/null 

if lsmod | grep br_netfilter | wc -l | grep -q "2" ; then
    echo "【SUCCESS】：br_netfilter配置成功"
else
    echo "【ERROR】：br_netfilter配置失败"
fi
if lsmod | grep overlay | wc -l | grep -q "1" ; then
    echo "【SUCCESS】：overlay配置成功"
else
    echo "【ERROR】：overlay配置失败"
fi

#!/bin/bash

# 定义预期参数
params=(
    "net.ipv6.conf.all.disable_ipv6=0"
    "net.ipv6.conf.default.disable_ipv6=0"
    "net.ipv6.conf.lo.disable_ipv6=0"
    "net.ipv6.conf.all.forwarding=1"
    "net.ipv6.conf.default.forwarding=1"
    "net.bridge.bridge-nf-call-iptables=1"
    "net.bridge.bridge-nf-call-ip6tables=1"
    "net.ipv4.ip_forward=1"
)

# 检查每个参数
all_ok=true
for expected in "${params[@]}"; do
    param="${expected%=*}"
    expected_value="${expected#*=}"
    current_value=$(sysctl -n "$param" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        if [ "$current_value" = "$expected_value" ]; then
            echo "✓ $param = $current_value (OK)"
        else
            echo "✗ $param = $current_value (期望: $expected_value)"
            all_ok=false
        fi
    else
        echo "! $param 参数不存在"
        all_ok=false
    fi
done

# 输出最终结果
if $all_ok; then
    echo "✓ sysctl所有参数检查通过 (OK)"
    exit 0
else
    echo "✗ sysctl部分参数不符合预期"
    exit 1
fi
