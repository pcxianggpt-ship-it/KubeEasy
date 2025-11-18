#!/bin/bash

## $1 为nfs路径
## $2 为nfs-server主机ip

if [[ -z "$1" ]]; then
    echo "【ERROR】： 缺少参数，请录入共享存储路径"
    exit 1
fi

mkdir -p $1

if cat /etc/exports | grep $1 | wc -l | grep -q "0" ; then
	echo "$1 *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
fi


systemctl restart nfs-server

if systemctl status nfs-server | grep Active: | grep active | grep -q "1" ; then
	echo "【SUCCESS】： nfs-server重启成功"
else
	echo "【ERROR】： nfs-server重启启动失败，请检查/etc/exports"
	exit 1
fi