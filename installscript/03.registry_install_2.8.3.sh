
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

# 检查容器运行时
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v nerdctl &> /dev/null; then
    CONTAINER_CMD="nerdctl"
else
    echo "【ERROR】：未找到容器运行时(docker或nerdctl)"
    exit 1
fi

echo "----正在解压镜像文件----"
echo "----每个.表示1000个文件----"
tar -xzf /data/registry-2.8.3.tar.gz -C /data --checkpoint=.1000
echo "----镜像文件解压成功----"

cd /data/docker-registry

$CONTAINER_CMD load -i rg2.8.3.tar > /dev/null 2>&1

if $CONTAINER_CMD images | grep registry | awk '{print $2}' | grep -q "2.8.3" ; then
    echo "【SUCCESS】：registry-2.8.3-$2.tar镜像导入成功"
else
    echo "【ERROR】：registry-2.8.3-$2.tar镜像导入失败"
    exit 1
fi


cat > config.yml <<EOF
version: 0.1
log:
  level: info
  fields:
    service: registry
storage:
  delete:
    enabled: true
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
    Access-Control-Allow-Origin: ["http://$1:5080"]
    Access-Control-Allow-Methods: ["HEAD", "GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    Access-Control-Allow-Headers: ["Authorization", "Content-Type", "Accept"]
    Access-Control-Max-Age: [1728000]
    Access-Control-Allow-Credentials: [true]
    Access-Control-Expose-Headers: ["Docker-Content-Digest"]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF


echo "----正在启镜像服务端----"

$CONTAINER_CMD run -d --name registry --restart always  -p 5000:5000 -v $(pwd)/registry-data:/var/lib/registry -v $(pwd)/config.yml:/etc/docker/registry/config.yml registry:2.8.3

echo "----镜像服务端启动成功----"

echo "----正在启动镜像服务----"

echo "----正在下载UI镜像----"
$CONTAINER_CMD pull $1:5000/joxit/docker-registry-ui:main
if $CONTAINER_CMD images | grep docker-registry-ui | wc -l | grep -q "1" ; then
    echo "【SUCCESS】：镜像仓库UI镜像拉取成功"
else
    echo "【ERROR】：镜像仓库UI镜像拉取失败"
    exit 1
fi


echo "----正在启动镜像仓库UI镜像----"
$CONTAINER_CMD run -d --name registry-ui-5080 --restart always -p 5080:80 \
    -e REGISTRY_TITLE=Registry \
    -e REGISTRY_URL=http://$1:5000 \
    -e DELETE_IMAGES=true \
    $1:5000/joxit/docker-registry-ui:main
echo "----镜像仓库UI启动成功----"

