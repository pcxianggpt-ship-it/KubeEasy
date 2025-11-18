
#!/bin/bash

if [[ -z "$1" ]]; then
    echo "【ERROR】： 请输入本机IP地址"
    exit 1
fi

if [[ -z "$2" ]]; then
    echo "【ERROR】： 请输入架构型号,arm或amd"
    exit 1
fi

if [[ -z "$3" ]]; then
    echo "【ERROR】： 请输入镜像仓库用户名"
    exit 1
fi

if [[ -z "$4" ]]; then
    echo "【ERROR】： 请输入镜像仓库密码"
    exit 1
fi

if [[ -z "$5" ]]; then
    echo "【ERROR】： 请输入镜像仓库是否加密"
    exit 1
fi

## 加载镜像
echo "----正在导入镜像----"

cd /data/k8s_install/04.registry/

docker load -i registry-2.7.1-$2.tar > /dev/null 2>&1
docker load -i registry-ui-$2.tar > /dev/null 2>&1

if docker images | grep registry | wc -l | grep -q "2" ; then
    echo "【SUCCESS】：registry-2.7.1-$2.tar、registry-ui-$2.tar镜像导入成功"
else
    echo "【ERROR】：registry-2.7.1-$2.tar、registry-ui-$2.tar镜像导入失败"
    exit 1
fi



echo "----正在解压镜像文件----"

tar -xzf registry-$2.tgz  -C /data
cd /data
mv registry registry_data

echo "----镜像文件解压成功----"


cd /data/registry_data

echo "----正在启动镜像UI----"

docker run -d --restart=always --name registry-ui-init -p 5080:80 \
-e REGISTRY_TITLE=Registry \
-e REGISTRY_URL=http://$1:5000 \
-e DELETE_IMAGES=true \
joxit/docker-registry-ui:2.2.2
#    registry-ui:arm64v8

echo "----镜像UI启动成功----"

echo "----正在启动镜像服务----"

if [[ $5 == "yes" ]]; then
    echo "镜像仓库用户名为 $3"
    echo "镜像仓库密码为 $4"
    
    set -e
    V_USER=$3  #访问镜像仓库的用户名
    V_PASSWORD=$4 #访问镜像仓库的密码
    rm -rf auth
    mkdir -p auth
    echo "创建auth路径"
    echo "创建密钥"
    htpasswd -bBc `pwd`/auth/htpasswd $V_USER $V_PASSWORD
    echo "finish htpasswd ......"
    echo "start:docker run ......"
    docker run -d --name registry-init \
        -p 5000:5000 \
        -v `pwd`/registry:/var/lib/registry \
        -v `pwd`/config.yml:/etc/docker/registry/config.yml \
        -v `pwd`/auth:/etc/docker/registry/auth \
        -e "REGISTRY_AUTH=htpasswd" \
        -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
        -e "REGISTRY_AUTH_HTPASSWD_PATH=/etc/docker/registry/auth/htpasswd" \
        registry:2.7.1
    echo "finish:docker run ......"

elif [[ $5 == "no" ]] then

    docker run -d --restart=always --name registry-init -p 5000:5000 \
    -v `pwd`/registry:/var/lib/registry \
    -v `pwd`/config.yml:/etc/docker/registry/config.yml \
    registry:2.7.1
fi


echo "----镜像服务启动成功----"