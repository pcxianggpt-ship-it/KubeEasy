## 参数说明
## $1 repo源名称

# 检查是否提供了参数
if [ -z "$1" ]; then
  echo "【ERROR】 : 01.yum.sh 缺少repo源名称参数"
  exit 1
fi

repo_source_name="$1"

# 1. 验证/var/www/html/$1文件是否存在
if [ ! -f "/var/www/html/$repo_source_name" ]; then
    echo "【ERROR】: YUM源文件不存在: /var/www/html/$repo_source_name"
    exit 1
fi

echo "【INFO】: 找到YUM源文件: /var/www/html/$repo_source_name"

cd  /var/www/html/
tar -zxf $repo_source_name

# 2. 添加.repo文件
if [ ! -s "/etc/yum.repos.d/k8s.repo" ]; then
cat << EOF | tee /etc/yum.repos.d/k8s.repo > /dev/null
[k8s-yum]
name=rhel7
baseurl=file:///var/www/html/repo/
enabled=1
gpgcheck=0
EOF
    echo "【INFO】: 创建k8s.repo文件"
else
    echo "【INFO】: k8s.repo文件已存在"
fi

# 3. 刷新缓存
yum -q clean all
yum -q makecache

# 4. 验证k8s yum源是否存在
echo "【INFO】: 验证k8s yum源..."
if [ $(yum -q search kubelet | wc -l)  -gt "0" ]; then
    echo "【SUCCESS】: 本地yum源已经安装"
    echo "【INFO】: kubelet包搜索结果:"
    yum search kubelet | head -5
else
    echo "【ERROR】: 本地yum源安装失败，无法找到kubelet包"
    exit 1
fi

# 5. 安装httpd并开机自启动服务
checkhttpd=$( systemctl status httpd 2>/dev/null | grep -c "active (running)" )
if [ $checkhttpd != "0" ]; then
    echo "【SUCCESS】: httpd服务已经安装并运行"
else
    echo "【INFO】: 正在安装httpd服务"
    yum -yq install httpd > /dev/null
    if [ $? -eq 0 ]; then
        echo "【SUCCESS】: httpd安装成功"
    else
        echo "【ERROR】: httpd安装失败"
        exit 1
    fi

    systemctl start httpd

    # 检查httpd服务状态
    checkhttpd=$( systemctl status httpd 2>/dev/null | grep -c "active (running)" )
    if [ $checkhttpd == "0" ]; then
        echo "【ERROR】: httpd服务启动失败"
        exit 1
    else
        echo "【SUCCESS】: httpd服务启动成功"
    fi
fi

# 设置httpd开机自启动
systemctl enable httpd > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "【SUCCESS】: httpd服务已设置开机自启动"
else
    echo "【ERROR】: httpd服务设置开机自启动失败"
    exit 1
fi

# 最终验证
echo "【INFO】: 最终验证yum源..."
if [ $(yum -q search kubelet | wc -l)  -gt "0" ]; then
    echo "【SUCCESS】: 本地repo源安装完成并验证通过"
    exit 0
else
    echo "【ERROR】: 本地repo源最终验证失败"
    exit 1
fi