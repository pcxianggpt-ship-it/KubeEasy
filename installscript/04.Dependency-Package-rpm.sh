#!/bin/bash

# check_conntrack_tools=$(rpm -qa | grep conntrack-tools | wc -l)

# if  [ ${check_conntrack_tools} == "1" ] ; then
# 	echo "【SUCCESS】： check_conntrack_tools 已经安装"
# else
# 	yum install -qy check_conntrack_tools

# 	check_conntrack_tools=$(rpm -qa | grep conntrack-tools | wc -l)
# 	if  [ ${check_conntrack_tools} == "1" ] ; then
# 		echo "【SUCCESS】： check_conntrack_tools 已经安装"
# 	else
# 		echo "【ERROR】： check_conntrack_tools 安装失败，请手动安装依赖conntrack_tools，重新执行脚本"
# 	exit 1
# 	fi
# fi

# check_socat=$(rpm -qa | grep socat | wc -l)

# if  [ ${check_socat} == "1" ] ; then
# 	echo "【SUCCESS】： socat 已经安装"
# else
# 	yum install -qy socat

# 	check_socat=$(rpm -qa | grep socat | wc -l)
# 	if  [ ${check_socat} == "1" ] ; then
# 		echo "【SUCCESS】： socat 已经安装"
# 	else
# 		echo "【ERROR】： socat 安装失败，请手动安装依赖socat，重新执行脚本"
# 	fi
# 	exit 1
# fi


cd /tmp/kubelet
rpm -ivh *.rpm



if  rpm -qa | grep cri-tools | wc -l | grep -q "1" ; then
	echo "【SUCCESS】： cri-tools 安装成功"
else
	echo "【ERROR】： cri-tools 安装失败"
	exit 1
fi

if  rpm -qa | grep kubelet | wc -l | grep -q "1" ; then
	echo "【SUCCESS】： kubelet 安装成功"
else
	echo "【ERROR】： kubelet 安装失败"
	exit 1
fi

if  rpm -qa | grep kubeadm | wc -l | grep -q "1" ; then
	echo "【SUCCESS】： kubeadm 安装成功"
else
	echo "【ERROR】： kubeadm 安装失败"
	exit 1
fi

if  rpm -qa | grep kubectl | wc -l | grep -q "1" ; then
	echo "【SUCCESS】： kubectl 安装成功"
else
	echo "【ERROR】： kubectl 安装失败" 
	exit 1
fi

if  rpm -qa | grep kubernetes-cni | wc -l | grep -q "1" ; then
	echo "【SUCCESS】： kubernetes-cni 安装成功"
else
	echo "【ERROR】： kubernetes-cni 安装失败"
	exit 1
fi


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