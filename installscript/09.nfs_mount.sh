#!/bin/bash

## $1 为共享存储路径
## $2 为当前服务器ip
## $3 为nfs-server的ip

if [[ -z "$1" ]]; then
    echo "【ERROR】： 缺少参数，请录入共享存储路径"
    exit 1
fi

if [[ -z "$2" ]]; then
    echo "【ERROR】： 缺少参数，请录入当前服务器ip"
    exit 1
fi

if [[ -z "$3" ]]; then
    echo "【ERROR】： 缺少参数，请录入nfs-server的ip"
    exit 1
fi

mkdir -p $1


if [ "$2" != "$3" ]; then

	# 挂载
	if findmnt $1 | grep $1 | wc -l | grep -q "0"; then
		mount -t nfs $3:$1 $1
		if findmnt $1 | grep $1 | wc -l | grep -q "1"; then
			echo "【SUCCESS】： $2 nfs挂载成功"
		else
			echo "【ERROR】： $2 nfs挂载失败"
		fi
	fi
	
	# 设置自动挂载
	if cat /etc/fstab | grep $1 | wc -l | grep -q "1"; then
		echo "【SUCCESS】： $2 nfs已设置自动挂载"
	else 
		echo "$3:$1 $1 nfs defaults 0 0 " >> /etc/fstab
		if cat /etc/fstab | grep $1 | wc -l | grep -q "1"; then
			echo "【SUCCESS】： $2 nfs自动挂载配置正确"
		else
			echo "【ERROR】： $2 nfs自动挂载配置异常，请检查/etc/fstab"
		fi
	fi
	
fi