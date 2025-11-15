#!/bin/bash

if [[ -z "$1" ]]; then
    echo "【ERROR】： 请输入本机IP地址"
    exit 1
fi

if [[ -z "$2" ]]; then
    echo "【ERROR】： 请输入工作路径"
    exit 1
fi

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
  advertiseAddress: "$1"
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
imageRepository: registry:5000/google_containers   #指定为前面安装registry的库，ex:1.1.1.1:5000/k8s
kind: ClusterConfiguration
kubernetesVersion: v1.23.17 #指定安装版本
controlPlaneEndpoint: "k8sc1:6443"  #开启该选项，以便后期升级为高可用集群
networking:
  dnsDomain: cluster.local
  podSubnet: 10.42.0.0/16
  serviceSubnet: 10.96.0.0/12
scheduler: {}
EOF


echo KUBELET_EXTRA_ARGS=\'--root-dir=$2/kubelet_root\' > /etc/sysconfig/kubelet

kubeadm init --upload-certs --config /tmp/k8s/cluster.yaml > /tmp/k8s/k8s-init-cluster.log



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


kubectl create secret docker-registry global-registry --docker-server=registry:5000 --docker-username=$registry_user --docker-password=$registry_passwd -n kube-system




# 初始化完成后，需要修改kube-controller-manager的参数，保证工作节点获取的证书也是一百年

scp /usr/bin/kubeadm /tmp/kubeadm_bak
scp /data/k8s_install/01.rpm_package/kubeadm100y-amd /usr/bin/kubeadm

if [ $(cat /etc/kubernetes/manifests/kube-controller-manager.yaml | grep cluster-signing-duration | wc -l )  -eq 0 ]; then
  sed -i "/use-service-account-credentials/a\\
    - --cluster-signing-duration=867240h0m0s" /etc/kubernetes/manifests/kube-controller-manager.yaml
fi



check_controller_manager=$(kubectl get po -A | grep controller-manager-k8sc1 | awk '{print $4}')
check_etcd=$(kubectl get po -A | grep etcd-k8sc1 | awk '{print $4}')
check_apiserver=$(kubectl get po -A | grep kube-apiserver-k8sc1 | awk '{print $4}')
check_proxy=$(kubectl get po -A | grep kube-proxy | awk '{print $4}')
check_scheduler=$(kubectl get po -A | grep kube-scheduler-k8sc1 | awk '{print $4}')


if [[ $check_controller_manager == "Running" ]]; then
  echo "【SUCCESS】： kube-controller-manager-k8sc1 启动成功"
else
  echo "【ERROR】： kube-controller-manager-k8sc1 启动失败"
  exit 1
fi
if [[ $check_etcd == "Running" ]]; then
  echo "【SUCCESS】： kube-controller-manager-k8sc1 启动成功"
else
  echo "【ERROR】： kube-controller-manager-k8sc1 启动失败"
  exit 1
fi
if [[ $check_apiserver == "Running" ]]; then
  echo "【SUCCESS】： kube-controller-manager-k8sc1 启动成功"
else
  echo "【ERROR】： kube-controller-manager-k8sc1 启动失败"
  exit 1
fi
if [[ $check_proxy == "Running" ]]; then
  echo "【SUCCESS】： kube-controller-manager-k8sc1 启动成功"
else
  echo "【ERROR】： kube-controller-manager-k8sc1 启动失败"
  exit 1
fi
if [[ $check_scheduler == "Running" ]]; then
  echo "【SUCCESS】： kube-controller-manager-k8sc1 启动成功"
else
  echo "【ERROR】： kube-controller-manager-k8sc1 启动失败"
  exit 1
fi


## 检查证书有效期
check_ca_time=$(kubeadm certs check-expiration | grep 99y | wc -l )

if [[ $check_ca_time == "13" ]]; then
    echo "【SUCCESS】： 证书有效期为99年"
else
    echo "【SUCCESS】： 证书有效期不为99年，请执行kubeadm certs check-expiration查看详情。"
    exit 1
fi