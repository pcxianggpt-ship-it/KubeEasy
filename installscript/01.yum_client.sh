#!/bin/bash

# 参数说明
# $1 registry ip 
# $2 当前机器ip


# 检查是否提供了参数
if [ -z "$1" ]; then
  echo "【ERROR】 : 01.yum_client.sh 缺少参数"
  exit 1
fi


cat <<EOF | tee /etc/yum.repos.d/k8s-http.repo > /dev/null
[k8s-repo]
name=http
baseurl=http://$1/repo
enabled=1
gpgcheck=0
EOF

yum -q clean all 
yum -q makecache

