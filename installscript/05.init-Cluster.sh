#!/bin/bash

# 参数验证
if [[ -z "$1" ]]; then
    echo "【ERROR】： 请输入是否双栈网络 (Y/N)"
    echo "用法: $0 <Y|N> [kubelet_data_dir]"
    echo "示例: $0 N /data"
    exit 1
fi


DualStack="$1"
KUBELET_DATA_DIR="$2"

# 参数验证
if [[ "$DualStack" != "Y" && "$DualStack" != "N" ]]; then
    echo "【ERROR】： 双栈网络参数只能是 Y 或 N"
    exit 1
fi

# 获取本机IPv4地址
ipv4=$(hostname -I | awk '{print $1}')
if [[ -z "$ipv4" ]]; then
    echo "【ERROR】： 无法获取本机IPv4地址"
    exit 1
fi

# 获取本机IPv6地址（如果需要）
if [[ "$DualStack" == "Y" ]]; then
    ipv6=$(ip -6 addr show scope global | grep -v 'fd00:42::171' | head -2 | awk '/inet6/ {print $2}' | cut -d'/' -f1)
    if [[ -z "$ipv6" ]]; then
        echo "【ERROR】： 无法获取本机IPv6地址，请检查网络配置"
        exit 1
    fi
else
    ipv6=""
fi

# 获取k8s version
k8s_version_output=$(kubelet --version 2>/dev/null)
if [[ $? -eq 0 ]]; then
    k8s_version=$(echo "$k8s_version_output" | awk '{print $2}')
else
    echo "【ERROR】： 无法获取kubelet版本信息"
    exit 1
fi

echo "配置信息："
echo "  双栈网络: $DualStack"
echo "  IPv4地址: $ipv4"
echo "  IPv6地址: ${ipv6:-'未启用'}"
echo "  K8s版本: $k8s_version"
echo "  Kubelet数据目录: $KUBELET_DATA_DIR"

# 确保临时目录存在
mkdir -p /tmp/k8s

if [[ "$DualStack" == 'N' ]]; then
cat << EOF |  tee /tmp/k8s/cluster.yaml > /dev/null
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
  advertiseAddress: "$ipv4"
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
    dataDir: /data/etcd_root #放在有足够空间的路径下
imageRepository: registry:5000/registry.k8s.io   #指定为前面安装registry的库，ex:1.1.1.1:5000/k8s
kind: ClusterConfiguration
kubernetesVersion: $k8s_version #指定安装版本
controlPlaneEndpoint: "k8sc1:6443"  #开启该选项，以便后期升级为高可用集群
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
scheduler: {}
EOF
elif [[ "$DualStack" == 'Y' ]]; then

cat << EOF |  tee /tmp/k8s/cluster.yaml > /dev/null
# ------------- InitConfiguration -------------
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
  advertiseAddress: "$ipv4"   # 控制平面监听 IPv4 地址
  bindPort: 6443

nodeRegistration:
  imagePullPolicy: IfNotPresent
  taints: null
  kubeletExtraArgs:
    # node-ip 必须是 IPv4 + 可达 IPv6 (不能是 link-local fe80)
    node-ip: "$ipv4,$ipv6"
---
# ------------- ClusterConfiguration -------------
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration

kubernetesVersion: $k8s_version
clusterName: kubernetes
certificatesDir: /etc/kubernetes/pki

controlPlaneEndpoint: "k8sc1:6443"   # 高可用入口

imageRepository: registry:5000/registry.k8s.io

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
else
  echo "【ERROR】:是否双栈网络参数非法"
fi






echo "KUBELET_EXTRA_ARGS='--root-dir=/data/kubelet_root'" > /etc/sysconfig/kubelet

# 检查配置文件是否生成成功
if [[ ! -f /tmp/k8s/cluster.yaml ]]; then
    echo "【ERROR】： 集群配置文件生成失败"
    exit 1
fi

echo "开始初始化Kubernetes集群..."
kubeadm init --upload-certs --config /tmp/k8s/cluster.yaml > /tmp/k8s/k8s-init-cluster.log 2>&1

# 检查初始化结果
if [[ $? -ne 0 ]]; then
    echo "【ERROR】： 集群初始化失败，请检查日志 /tmp/k8s/k8s-init-cluster.log"
    echo "最近20行错误信息："
    tail -20 /tmp/k8s/k8s-init-cluster.log
    exit 1
fi



if cat /tmp/k8s/k8s-init-cluster.log | grep "kubeadm join" | wc -l | grep -q "2" ; then
  # 配置环境变量
  mkdir -p $HOME/.kube
  scp /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  export KUBECONFIG=/etc/kubernetes/admin.conf
  echo "【SUCCESS】： 集群初始化成功"
else
   echo "【ERROR】： 集群初始化失败，请检查日志/tmp/k8s/k8s-init-cluster.log"
   exit 1
fi


cat /tmp/k8s/k8s-init-cluster.log | grep "kubeadm join" -A2 | sed -n '1,3p' > /tmp/k8s/kube_join_master
cat /tmp/k8s/k8s-init-cluster.log | grep "kubeadm join" -A2 | sed -n '5,6p' > /tmp/k8s/kube_join_nodes




echo "等待Pod启动完毕，等待60秒"
sleep 60


# 修改kube-controller-manager配置
if [[ -f /etc/kubernetes/manifests/kube-controller-manager.yaml ]]; then
    if ! grep -q "cluster-signing-duration" /etc/kubernetes/manifests/kube-controller-manager.yaml; then
        echo "添加cluster-signing-duration参数..."
        sed -i '/use-service-account-credentials/a\\    - --cluster-signing-duration=867240h0m0s' /etc/kubernetes/manifests/kube-controller-manager.yaml
        echo "【SUCCESS】： 已添加证书有效期配置"
        # 等待kube-controller-manager重启
        echo "等待kube-controller-manager重启..."
        sleep 30
    else
        echo "【INFO】： cluster-signing-duration参数已存在"
    fi
else
    echo "【ERROR】： kube-controller-manager配置文件不存在"
fi



echo "检查系统Pod状态..."

# 检查关键系统Pod状态
declare -A critical_pods=(
    ["controller-manager"]="kube-controller-manager-k8sc1"
    ["etcd"]="etcd-k8sc1"
    ["apiserver"]="kube-apiserver-k8sc1"
    ["scheduler"]="kube-scheduler-k8sc1"
)

all_pods_running=true

for pod_type in "${!critical_pods[@]}"; do
    pod_name="${critical_pods[$pod_type]}"
    pod_status=$(kubectl get po -n kube-system | grep "$pod_name" | awk '{print $3}' | head -1)

    if [[ "$pod_status" == "Running" ]]; then
        echo "【SUCCESS】： $pod_name 启动成功"
    else
        echo "【ERROR】： $pod_name 启动失败 (状态: ${pod_status:-'Not Found'})"
        all_pods_running=false
    fi
done

# 检查kube-proxy (可能有多个实例)
echo "检查kube-proxy状态..."
kube_proxy_status=$(kubectl get po -n kube-system -l k8s-app=kube-proxy --no-headers | awk '{print $3}' | sort | uniq)
if [[ "$kube_proxy_status" == "Running" ]]; then
    echo "【SUCCESS】： kube-proxy 启动成功"
else
    echo "【ERROR】： kube-proxy 启动失败 (状态: ${kube_proxy_status:-'Not Found'})"
    all_pods_running=false
fi

# 如果有关键Pod未运行，退出脚本
if [[ "$all_pods_running" != "true" ]]; then
    echo "【ERROR】： 关键系统Pod未全部运行，请检查集群状态"
    echo "所有系统Pod状态："
    kubectl get po -n kube-system
    exit 1
fi


# 检查证书有效期
echo "检查集群证书有效期..."
if ! command -v kubeadm >/dev/null 2>&1; then
    echo "【WARNING】： kubeadm命令不可用，跳过证书有效期检查"
else
    echo "证书有效期信息："
    kubeadm certs check-expiration

    # 检查是否有99年有效期的证书
    ca_99y_count=$(kubeadm certs check-expiration | grep -c "99y")

    if [[ $ca_99y_count -ge 10 ]]; then
        echo "【SUCCESS】： 证书有效期配置正确 (99年证书数量: $ca_99y_count)"
    else
        echo "【ERROR】： 证书有效期不是99年，集群初始化失败！"
        echo "请检查证书配置并重新初始化集群"
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo "【SUCCESS】： Kubernetes集群初始化完成！"
echo "=========================================="
echo "集群访问信息："
echo "- 配置文件: /etc/kubernetes/admin.conf"
echo "- 用户配置: $HOME/.kube/config"
echo "- 查看节点: kubectl get nodes"
echo "- 查看Pod: kubectl get po -A"
echo ""
echo "加入集群的命令已保存到："
echo "- 控制节点: /tmp/k8s/kube_join_master"
echo "- 工作节点: /tmp/k8s/kube_join_nodes"
echo "=========================================="