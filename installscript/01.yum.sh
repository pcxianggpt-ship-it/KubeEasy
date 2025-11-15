## 参数说明
## $1 repo源ip
## $2 k8s_install路径
## $3 master1 ip

# 检查是否提供了参数
if [ -z "$1" ]; then
  echo "【ERROR】 : 01.yum_server.sh 缺少repo源ip参数"
  exit 1
fi
if [ -z "$2" ]; then
  echo "【ERROR】 : 01.yum_server.sh 缺少k8s_install路径参数"
  exit 1
fi
if [ -z "$3" ]; then
  echo "【ERROR】 : 01.yum_server.sh 缺少master1 ip参数"
  exit 1
fi

if [ ! -s "/etc/yum.repos.d/local.repo" ]; then

cat << EOF | tee /etc/yum.repos.d/local.repo > /dev/null
[local-yum]
name=rhel7
baseurl=file:///var/www/html/kylinos/Packages
enabled=1  
gpgcheck=0
EOF

fi

if [[ -f /etc/yum.repos.d/kylin_x86_64.repo ]]; then
    mv /etc/yum.repos.d/kylin_x86_64.repo /etc/yum.repos.d/kylin_x86_64.repo.bak > /dev/null
fi


yum -q clean all
yum -q makecache

# 如果能找不到conntrack，说明源没有安装，如果能找到直接跳过

if [ $(yum -q search kubelet | wc -l)  -gt "0" ]; then
    echo "【SUCCESS】: 本地yum源已经安装"
else
    mkdir -p /var/www/html

#    # 挂载iso文件
#    checkmount=$(ls $2/k8s_install/06.repo/repo | wc -l)
#    if [[ $checkmount == "0"  ]]; then
#        mount -o loop $2/k8s_install/06.repo/*.iso $2/k8s_install/06.repo/repo
#    fi
#    
#    if [[ ! -d  $2/k8s_install/06.repo/repo/repodata ]]; then
#        echo "【ERROR】: 源文件挂载失败"
#        exit 1
#    fi
#
#    #检查是否已经复制
#    checkRpmNum=$(ls /var/www/html/kylinos/Packages | wc -l)
#    if [[ $checkRpmNum -lt "100" ]]; then
#        scp $2/k8s_install/06.repo/repo/Packages/*.rpm /var/www/html/kylinos/Packages
#        scp $2/k8s_install/01.rpm_package/kubelet/*.rpm  /var/www/html/kylinos/Packages
#        scp -r $2/k8s_install/06.repo/repo/repodata /var/www/html/kylinos
#    fi
#
#    yum clean all > /dev/null
#    yum makecache > /dev/null

    tar -xzf $2/k8s_install/06.repo/*.tar -C /var/www/html
    yum -q clean all
    yum -q makecache

    if [ $(yum -q search kubelet | wc -l)  -gt "0" ]; then
        echo "【SUCCESS】: 本地yum源已经安装"
    else
        echo "【ERROR】: 本地yum源安装失败"
        exit 1
    fi
fi




checkhttpd=$( systemctl status httpd | grep Active | wc -l )
if [ $checkhttpd != "0" ]; then
    echo "【SUCCESS】: httpd服务已经安装"
else
    echo "正在安装httpd"
    yum -yq install httpd > /dev/null
    echo "httpd安装结束"
    
    checkhttpd=$( systemctl status httpd | grep Active | wc -l )
    if [ $checkhttpd == "0" ]; then
        echo "【SUCCESS】: httpd服务安装失败"
        exit 1
    fi
fi


## 配置httpd
# httpd_conf=$( cat /etc/httpd/conf/httpd.conf | grep kylinos | wc -l )

# if [ $httpd_conf  == "0" ]; then
# cat << EOF | tee -a /etc/httpd/conf/httpd.conf > /dev/null
# DocumentRoot "/var/www/html/kylinos"
# <Directory "/var/www/html/kylinos/">
#     Options Indexes FollowSymLinks
#     AllowOverride None
#     Require all granted
# </Directory>
# EOF
# fi

systemctl enable httpd > /dev/null
systemctl restart httpd


if  [ $(yum -q search kubelet | wc -l)  -gt "0" ]; then
    echo "【SUCCESS】: 本地repo源已经安装"
else
    echo "【ERROR】: 本地repo源安装失败"
    exit 1
fi