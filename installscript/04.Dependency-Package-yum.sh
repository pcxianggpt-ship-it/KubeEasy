#!/bin/bash

yum install -y cri-tools kubeadm kubectl kubelet kubernetes-cni > /tmp/k8s_kubenetes.log


systemctl enable kubelet > /dev/null 2>&1
if  systemctl list-unit-files -t service | grep kubelet | awk '{print $NF}' | grep -q "enabled" ; then
	echo "【SUCCESS】： kubelet 已设置自启动"
else
	echo "【ERROR】： kubelet 未设置自启动，请检查"
	exit 1
fi



## 备份kubeadm
scp /usr/bin/kubeadm /tmp/kubeadm_bak
