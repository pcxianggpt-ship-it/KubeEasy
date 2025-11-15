#!/bin/bash

yum install -y cri-tools kubeadm kubectl kubelet kubernetes-cni > /tmp/k8s_kubenetes.log

if  rpm -qa | grep cri-tools | grep -q "cri-tools-1.23.0-0.x86_64" ; then
	echo "【SUCCESS】： cri-tools 安装成功"
else
	echo "【ERROR】： cri-tools 安装失败"
	exit 1
fi

if  rpm -qa | grep kubelet | grep -q "kubelet-1.23.10-0.x86_64" ; then
	echo "【SUCCESS】： kubelet 安装成功"
else
	echo "【ERROR】： kubelet 安装失败"
	exit 1
fi

if  rpm -qa | grep kubeadm | grep -q "kubeadm-1.23.10-0.x86_64" ; then
	echo "【SUCCESS】： kubeadm 安装成功"
else
	echo "【ERROR】： kubeadm 安装失败"
	exit 1
fi

if  rpm -qa | grep kubectl | grep -q "kubectl-1.23.10-0.x86_64" ; then
	echo "【SUCCESS】： kubectl 安装成功"
else
	echo "【ERROR】： kubectl 安装失败" 
	exit 1
fi

if  rpm -qa | grep kubernetes-cni | grep -q "kubernetes-cni-0.8.7-0.x86_64" ; then
	echo "【SUCCESS】： kubernetes-cni 安装成功"
else
	echo "【ERROR】： kubernetes-cni 安装失败"
	exit 1
fi

# 备份kubeadm

scp /usr/bin/kubeadm /tmp/kubeadm_bak
scp /data/k8s_install/01.rpm_package/kubeadm100y-amd /usr/bin/kubeadm

systemctl enable kubelet > /dev/null 2>&1
if  systemctl list-unit-files -t service | grep kubelet | awk '{print $NF}' | grep -q "enabled" ; then
	echo "【SUCCESS】： kubelet 已设置自启动"
else
	echo "【ERROR】： kubelet 未设置自启动，请检查"
	exit 1
fi

systemctl enable systemd-resolved > /dev/null 2>&1
if  systemctl list-unit-files -t service | grep systemd-resolved | awk '{print $NF}' | grep -q "enabled" ; then
	echo "【SUCCESS】： kubernetes-cni 安装成功"
else
	echo "【ERROR】： kubernetes-cni 安装失败"
	exit 1
fi