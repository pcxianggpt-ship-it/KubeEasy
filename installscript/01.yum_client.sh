#!/bin/bash

# 参数说明
# $1 registry ip 
# $2 当前机器ip


# 检查是否提供了参数
if [ -z "$1" ]; then
  echo "【ERROR】 : 01.yum_client.sh 缺少参数"
  exit 1
fi

# 检查是否提供了参数
if [ -z "$2" ]; then
  echo "【ERROR】 : 01.yum_client.sh 缺少参数"
  exit 1
fi


mv /etc/yum.repos.d/kylin_x86_64.repo /etc/yum.repos.d/kylin_x86_64.repo.bak > /dev/null

cat <<EOF | tee /etc/yum.repos.d/http.repo > /dev/null
[http]
name=http
baseurl=http://$1/kylinos
enabled=1
gpgcheck=0
EOF

yum -q clean all 
yum -q makecache

