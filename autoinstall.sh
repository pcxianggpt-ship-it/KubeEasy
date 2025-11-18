#!/bin/bash

# cpu架构
arch=amd

# 文件存储路径
data_path=/data



# nfs-server服务器
nfs_server_ip=192.168.62.174
nfs_path=/data/nfs_root


# 镜像仓库是否加密
ifpassword=no
# 镜像仓库用户名和密码
registry_user=amarsoft
registry_passwd=amarsoft@123


# 是否安装es
ifes=no

# 是否安装loki
ifloki=no

# 定义服务器信息

cat << EOF > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
192.168.62.171 k8sc1
192.168.62.172 k8sc2
192.168.62.173 k8sc3
192.168.62.174 k8sw1
192.168.62.175 k8sw2
192.168.62.176 k8sw3
192.168.62.188 k8sw4
192.168.63.184 registry
EOF


sh /data/k8s_install/06.InstallScrpit/generate_hosts.sh
source /tmp/hostsname.sh

# 控制节点（第一个为主节点）
master_ips=("$k8sc1_ip" "$k8sc2_ip" "$k8sc3_ip")
# 工作节点
worker_ips=("$k8sw1_ip" "$k8sw2_ip" "$k8sw3_ip" "$k8sw4_ip" )

dns_ip=("192.168.62.1")



k8s_nodes=("${master_ips[@]}" "${worker_ips[@]}")
all_nodes=("${master_ips[@]}" "${worker_ips[@]}" "${registry_ip[@]}")

echo "master节点ip：${master_ips[@]}"
echo "worker节点ip：${worker_ips[@]}"
echo "所有节点ip（不含镜像仓库）：${k8s_nodes[@]}"
echo "所有节点ip（包含镜像仓库）：${all_nodes[@]}"


## 阶段状态检查方法
exit_status_check(){
  exit_status=$?
  if [ $exit_status -eq 0 ]; then
      echo " **** STATUS_CHECK  【SUCCESS】：： $1 检查通过 **** "
      
  else
  	echo " **** STATUS_CHECK  【ERROR】：$1 检查失败 **** "
  	exit 1
  fi
}

ssh_command(){
	ssh root@$1 $2 > /dev/null 2>&1
}


## =====================   0.配置服务器免密登录 =================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 0.开始服务器免密登录 ===================="

sh /data/k8s_install/06.InstallScrpit/0.ssh_nopasswd.sh "${all_nodes[@]}"


echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 0.开始配置主机名和/etc/hosts ===================="

# 控制节点
master_counter=1
for m_ip in "${master_ips[@]}"
do
    echo "当前机器IP为: $m_ip"
    scp /etc/hosts root@$m_ip:/etc/hosts 2>/dev/null
	ssh root@$m_ip "hostnamectl set-hostname k8sc$master_counter" 2>/dev/null
	master_counter=$((master_counter + 1))
done
# 工作节点
worker_counter=1
for w_ip in "${worker_ips[@]}"
do
    echo "当前机器IP为: $w_ip"
    scp /etc/hosts root@$w_ip:/etc/hosts 2>/dev/null
	ssh root@$w_ip "hostnamectl set-hostname k8sw$worker_counter" 2>/dev/null
	worker_counter=$((worker_counter + 1))
done

# 镜像仓库，独立镜像仓库配置hostname
if [[ " ${k8s_nodes[@]} " =~ " $registry_ip " ]]; then
    echo "非独立镜像仓库"
else
    echo "使用独立镜像仓库"
    scp /etc/hosts root@$registry_ip:/etc/hosts 2>/dev/null
	ssh root@$registry_ip "hostnamectl set-hostname registry" 2>/dev/null
fi


## =====================   1.配置环境变量   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始配置环境变量 ====================="


for m_ip in "${master_ips[@]}"
do
    echo "当前机器IP为: $m_ip"
    ssh root@$m_ip 'bash -s' < /data/k8s_install/06.InstallScrpit/01.set-env.sh $data_path 2>/dev/null
done
for w_ip in "${worker_ips[@]}"
do
    echo "当前机器IP为: $w_ip"
    ssh root@$w_ip 'bash -s' < /data/k8s_install/06.InstallScrpit/01.set-env.sh $data_path 2>/dev/null
done

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始配置DNS ====================="

for a_ip in "${k8s_nodes[@]}"
do
    echo "当前机器IP为: $a_ip"
    ssh root@$a_ip 'bash -s' < /data/k8s_install/06.InstallScrpit/01.dns.sh $dns_ip 2>/dev/null
done




# echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始配置本地源yum-server ====================="

# # 配置yum源 server，yum源默认安装在镜像仓库服务器


# if  [ $(curl -s $registry_ip/kylinos/repodata/repomd.xml | grep linux.duke.edu | wc -l )  -gt "0" ]; then
# 	echo "【SUCCESS】: 本地repo源已经安装"
# else
# 	echo "正在复制repo文件至/var/www/html/kylinos，请等待"
# 	ssh root@$registry_ip "echo 'aa' && mkdir -p $data_path/k8s_install/06.repo/repo && mkdir -p $data_path/k8s_install/01.rpm_package" # 2>/dev/null
# 	scp $data_path/k8s_install/06.repo/*.iso root@$registry_ip:$data_path/k8s_install/06.repo
# 	scp -r $data_path/k8s_install/01.rpm_package/kubelet root@$registry_ip:$data_path/k8s_install/01.rpm_package
# 	echo "repo文件复制完成"
# 	ssh root@$registry_ip 'bash -s' < ./06.InstallScrpit/01.yum.sh $registry_ip $data_path $master_ips  2>/dev/null
# fi
# exit_status_check "本地源yum-server"


# echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始配置本地yum-client ====================="
# # 配置yum client

# for a_ip in "${k8s_nodes[@]}"
# do
#   if [ ${a_ip} = ${registry_ip} ]; then
#     echo "【SUCCESS】: 当前机器为repo-server，跳过yum-client配置"
#   else
#     echo "当前机器IP为: $a_ip "
#     ssh root@$a_ip "bash -s" < ./06.InstallScrpit/01.yum_client.sh $registry_ip $a_ip 2>/dev/null
#     if [ $(ssh root@$a_ip "yum -q search kubelet | wc -l " 2>/dev/null )  -gt "0" ] ; then
#         echo "【SUCCESS】: $a_ip repo-client 配置成功"
#     else
#         echo "【ERROR】: $a_ip repo-client 配置失败"
#         exit 1
#     fi
#   fi
# done

# exit_status_check "本地源yum-client"




## =====================   2.安装docker   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始安装docker ====================="

tar -xzf /data/k8s_install/02.install_package/docker-20.10.24.tgz -C /data/k8s_install/02.install_package/

for a_ip in "${all_nodes[@]}"
do
	if ssh root@$a_ip  "docker info | wc -l " 2>/dev/null | grep -q "53" 2>&1 ; then
        echo "【SUCCESS】：$a_ip docker已经安装"
    else
		echo "当前安装的机器IP为: $a_ip "
		scp /data/k8s_install/02.install_package/docker/* root@$a_ip:/usr/bin > /dev/null 2>&1
    	ssh root@$a_ip 'bash -s' < /data/k8s_install/06.InstallScrpit/02.docker_install.sh $registry_ip 2>/dev/null
	    if ssh root@$a_ip  "docker info | wc -l "| grep -q "53" ; then
            echo "【SUCCESS】：$a_ip docker安装成功"
        else
       	    echo "【ERROR】： $a_ip docker info执行不正常，请检查相关配置！"
            exit 1
        fi
    fi
done



### =====================   3.安装镜像仓库   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始安装镜像仓库 ====================="

check_registry_init=$(docker login registry:5000 -u $registry_user -p $registry_passwd 2>&1 | grep Succeeded | wc -l)
if [ $check_registry_init == "1" ]; then
	echo "【SUCCESS】：镜像仓库已经安装"
else
	# 镜像仓库如果不安装在k8sc1节点上，则需要复制文件
	if [ "${master_ips}" != "${registry_ip}" ]; then
	    echo "正在复制镜像仓库文件。。。。"
	    scp -r /data/k8s_install/04.registry root@$registry_ip:/data/k8s_install > /dev/null 2>&1
	    echo "镜像仓库文件复制完毕。。。。"
    fi

    #安装镜像仓库
    ssh root@$registry_ip 'bash -s' < /data/k8s_install/06.InstallScrpit/03.registry_install.sh $registry_ip $arch $registry_user $registry_passwd $ifpassword 2>/dev/null

    # 验证是否安装成功
    check_registry_init=$(docker login registry:5000 -u $registry_user -p $registry_passwd 2>&1 | grep Succeeded | wc -l)
    if [ $check_registry_init == "1" ]; then
	    echo "【SUCCESS】：镜像仓库安装成功"
	else
	    echo "【ERROR】： 镜像仓库安装失败，请检查"
	    exit 1
	fi
fi

exit_status_check "镜像仓库安装失败"


## =====================   4.安装依赖   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始安装依赖 ====================="

for a_ip in "${k8s_nodes[@]}"
do
	echo "当前安装的机器IP为: $a_ip "
	scp -r /data/k8s_install/01.rpm_package/kubelet root@$a_ip:/tmp > /dev/null 2>&1
	ssh root@$a_ip 'bash -s' < /data/k8s_install/06.InstallScrpit/04.Dependency-Package-rpm.sh 2>/dev/null
	
exit_status_check "$a_ip  依赖检查"

done



## =====================   5.初始化集群   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 开始初始化集群 ====================="

mkdir -p /tmp/k8s

docker login registry:5000 -u $registry_user -p $registry_passwd 2>/dev/null

for a_ip in "${k8s_nodes[@]}"
do
	echo "$a_ip : docker login  && docker pull pause:3.6、kube-proxy:v1.23.17"
	ssh root@$a_ip  "docker login registry:5000 -u $registry_user -p $registry_passwd"  2>/dev/null
	ssh root@$a_ip  "docker pull registry:5000/google_containers/pause:3.6" > /dev/null 2>&1
	ssh root@$a_ip  "docker pull registry:5000/google_containers/kube-proxy:v1.23.17" > /dev/null 2>&1
	ssh root@$a_ip  "docker pull registry:5000/google_containers/coredns:v1.8.6" > /dev/null 2>&1
done


if [ $(kubectl get nodes | grep k8sc1 | wc -l) -gt "0" ]; then
	echo "【SUCCESS】：集群已初始化"
else
	sh /data/k8s_install/06.InstallScrpit/05.init-Cluster.sh $master_ips $data_path
fi

exit_status_check "初始化集群"

## =====================   6.加入控制节点   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 6.加入控制节点 ====================="
for m_ip in "${master_ips[@]}"
do
	if [[ $m_ip != ${master_ips} ]]; then
		if [ $(kubectl get nodes -o wide | grep $m_ip | wc -l ) -eq 1 ]; then
			echo "【SUCCESS】： $m_ip 控制节点已加入集群"
		else
			echo "当前安装的机器IP为: $m_ip "
			ssh root@$m_ip 'bash -s' < /tmp/k8s/kube_join_master > /tmp/k8s/07.k8s_join_master.log 2>/dev/null
			# 配置环境变量
			ssh root@$m_ip 'bash -s' < ./06.InstallScrpit/06.set-admin-conf.sh 2>/dev/null
			# 检查节点是否加入成功
			if [ $(kubectl get nodes -o wide | grep "$m_ip" |  wc -l) -eq 1 ]; then
				echo "【SUCCESS】： $m_ip 控制节点加入成功"
			else
				echo "【ERROR】： $m_ip 控制节点加入失败，请检查节点信息"
				exit 1
			fi
			
			echo "等待控制节点启动完成，30秒"
			sleep 30
		fi
	fi
done


## =====================   7.加入工作节点   =====================##
echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 7.加入工作节点 ====================="

for w_ip in "${worker_ips[@]}"
do
	if [ $(kubectl get nodes -o wide | grep $w_ip | wc -l ) -eq 1 ]; then
		echo "【SUCCESS】： $w_ip 工作节点已加入集群"
	else
		echo "当前安装的机器IP为: $w_ip "
		ssh root@$w_ip 'bash -s' < /tmp/k8s/kube_join_nodes > /tmp/k8s/07.k8s_join_node.log 2>/dev/null

		# 检查节点是否加入成功
		if [ $(kubectl get nodes -o wide | grep "$w_ip" |  wc -l) -eq 1 ]; then
			echo "【SUCCESS】： $w_ip 工作节点加入成功"
		else
			echo "【ERROR】： $w_ip 工作节点加入失败，请检查节点信息"
			exit 1
		fi
	fi

done


### =====================   8.配置RemoveSelfLink   =====================##
#

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 8.配置RemoveSelfLink ====================="

for m_ip in "${master_ips[@]}"
do
	podname=$(kubectl get pod -A -o wide | grep -i apiserver | grep "$m_ip" | awk '{print $2}')

	if [ $( kubectl get pod $podname -n kube-system -o yaml | grep "RemoveSelfLink=false" | wc -l ) -eq "1" ]; then
		echo "【SUCCESS】： $m_ip RemoveSelfLink参数已配置"
	else
		ssh root@$m_ip 'bash -s' < ./06.InstallScrpit/08.RemoveSelfLink.sh $m_ip 2>/dev/null
		exit_status_check "$m_ip RemoveSelfLink"
	fi

done



## =====================   9.安装flannel   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 9.安装flannel ====================="

kubectl create ns kube-flannel
kubectl create secret docker-registry global-registry --docker-server=registry:5000 --docker-username=$registry_user --docker-password=$registry_passwd -n kube-flannel


if [ $(kubectl get pod -A | grep kube-flannel | grep Running | wc -l) -eq ${#k8s_nodes[@]} ]; then
	echo "【SUCCESS】： kube-flannel安装成功"
else
	kubectl apply -f $data_path/k8s_install/03.setup_file/kube-flannel.yml > /dev/null 2>&1

	flannel_counter=1
	while true; do
	   
	   # 检查 Pod 状态是否为 Running
	   if kubectl get pod -n kube-flannel | grep -i Running | wc -l | grep -q "${#k8s_nodes[@]}" ; then
	       echo "【SUCCESS】： kube-flannel启动成功"
	       break
	   fi
	   
	   # 增加计数器
	   flannel_counter=$((flannel_counter + 1))
	   
	   # 检查计数器是否达到最大尝试次数
	   if [ "$flannel_counter" -ge "10" ]; then
	       echo "【ERROR】： kube-flannel启动失败"
	       exit 1
	   fi
	   
	   # 等待 5 秒
	   sleep 5
	done
fi



## =====================   10.安装nfs   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 10.安装配置nfs ====================="

for a_ip in "${k8s_nodes[@]}"
do
	command="systemctl status nfs | grep Loaded | wc -l | grep -eq \"1\""
	if  ssh_command $a_ip $command  ; then
		echo "【SUCCESS】： nfs已经安装"
	else
		ssh root@$a_ip "yum install -y nfs-utils" > /dev/null 2>&1
		ssh root@$a_ip "systemctl enable nfs-server && systemctl start nfs-server" > /dev/null 2>&1
		if  ssh root@$a_ip systemctl status nfs | grep Loaded | wc -l | grep -q "1" ; then
			echo "【SUCCESS】： $a_ip nfs安装成功"
		else
			echo "【ERROR】： $a_ip nfs安装失败，请手动安装依赖"
			exit 1
		fi
	fi
done


# 配置nfs-server


echo "开始配置nfs-server "
ssh root@$nfs_server_ip 'bash -s' < ./06.InstallScrpit/09.nfs_server.sh $nfs_path 2>/dev/null


# 挂载
for a_ip in "${k8s_nodes[@]}"
do
	echo "开始挂载/验证 $a_ip"
	ssh root@$a_ip 'bash -s' < ./06.InstallScrpit/09.nfs_mount.sh $nfs_path $a_ip $nfs_server_ip 2>/dev/null
done



# 测试nfs
ssh root@$nfs_server_ip "touch $nfs_path/test.log" 2>/dev/null

for a_ip in "${k8s_nodes[@]}"
do
	if ssh root@$a_ip "ls $nfs_path/test.log | grep test.log | wc -l | grep -q  '1'" 2>/dev/null ; then
		echo "【SUCCESS】： $a_ip nfs测试成功"
	else
		echo "【ERROR】： $a_ip nfs测试失败"
		exit 1
	fi
done

ssh root@$nfs_server_ip "rm $nfs_path/test.log" 2>/dev/null



# 安装 0.nfs.yaml

kubectl create secret docker-registry global-registry --docker-server=registry:5000 --docker-username=$registry_user --docker-password=$registry_passwd

check_nfs_provide=$( kubectl get pod | grep  nfs | grep Running | wc -l  )
if [[  $check_nfs_provide == "3" ]]; then
	echo "【SUCCESS】： 0-nfs.yml运行正常"
else
    cp $data_path/k8s_install/03.setup_file/allyaml/0-nfs.yml /tmp/0-nfs.yml
    sed -i "s/38.62.44.69/$nfs_server_ip/g" /tmp/0-nfs.yml
    sed -i "s#/home/app/nfs_root#$nfs_path#g" /tmp/0-nfs.yml
    kubectl delete -f /tmp/0-nfs.yml > /dev/null 2>&1
    kubectl apply -f /tmp/0-nfs.yml > /dev/null 2>&1
fi


## =====================   10.安装kubemate   =====================##

# 定义文件路径

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 10.安装kubemate ====================="

kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/0.kubemate-namespace.yaml
kubectl create secret docker-registry global-registry --docker-server=registry:5000 --docker-username=$registry_user --docker-password=$registry_passwd -n kubemate-system
kubectl create secret docker-registry global-registry --docker-server=registry:5000 --docker-username=$registry_user --docker-password=$registry_passwd -n kubemate-opt


KUBE_CONFIG="$HOME/.kube/config"
KUBEMATE_FILE="/tmp/1.kubemate.yml"
scp $data_path/k8s_install/03.setup_file/allyaml/1.kubemate.yml $KUBEMATE_FILE


# 替换hostAliases
sed -i "s/10.33.1.16/$master_ips/g" $KUBEMATE_FILE

kubectl apply -f $KUBEMATE_FILE
kubectl apply -f $KUBEMATE_FILE

## =====================   11.安装es   =====================##

if [[ $ifes == "yes" ]]; then
	echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 11.安装es ====================="
	kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/2.es-crds.yml
	kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/2.es-operator.yml
	kubectl create secret docker-registry global-registry --docker-server=registry:5000 --docker-username=$registry_user --docker-password=$registry_passwd -n elastic-system
	kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/2.es-skywalking.yml
	
	
	## =====================   12.安装skywalking   =====================##
	
	echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 12.安装skywalking ====================="
	# 获取es密码
	sleep 5
	ES_PASSWORD=$(kubectl get -n kubemate-system  secret es-skywalking-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')
	
	if [[ -z $ES_PASSWORD ]]; then
		echo "【ERROR】: ES_PASSWORD为空，检查2.es-skywalking.yml是否部署成功"
	else
		cp $data_path/k8s_install/03.setup_file/allyaml/3.skywalking-es.yml /tmp/3.skywalking-es.yml
		sed -i "s/^.*ES_PASSWORD.*$/  ES_PASSWORD: $ES_PASSWORD/" /tmp/3.skywalking-es.yml
		kubectl apply -f /tmp/3.skywalking-es.yml
	fi
fi



if [[ $ifloki == "yes" ]]; then
	## =====================   12.安装loki   =====================##
	echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 12.安装loki ====================="
	
	scp $data_path/k8s_install/03.setup_file/allyaml/4.loki.yml /tmp/4.loki.yml
	sed -i "s#/data/docker_root/containers#$data_path/docker_root/containers#g" /tmp/4.loki.yml
	
	kubectl apply -f /tmp/4.loki.yml
	kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/4.loki-sec.yml

fi


## =====================   13.安装traefik   =====================##
echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 13.安装traefik ====================="
kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/5.traefik-ds.yml
kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/5.traefik-ds.yml
kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/6.logfmt-manage.yml
kubectl apply -f $data_path/k8s_install/03.setup_file/allyaml/5-1.traefik-mesh.yml

## =====================   14.安装prometheus   =====================##
echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 14.安装prometheus ====================="

cd $data_path/k8s_install/03.setup_file/allyaml/prometheus
kubectl create -f 1-crd.yml
kubectl apply -f 2-namespace.yml
kubectl create secret docker-registry global-registry --docker-server=registry:5000 --docker-username=$registry_user --docker-password=$registry_passwd -n kubemate-monitoring-system
kubectl apply -f 3-rbac.yml
kubectl apply -f 4-prometheus-operator.yml
kubectl apply -f 5-additional-scrape-configs.yml
kubectl apply -f 6-prometheus.yml
kubectl apply -f 7-alertmanager.yml
kubectl apply -f 8-prometheus-rule.yml
kubectl apply -f node-exporter.yml
kubectl apply -f kube-state-metrics.yml


## =====================   15.更新coredns配置   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 15.更新coredns配置 ====================="
cd /data/k8s_install/03.setup_file/allyaml
kubectl apply -f coredns-update.yml
kubectl rollout restart -n kube-system deployment coredns
sleep 5 
kubectl rollout restart deployment/traefik-mesh-controller -n kubemate-system

#设置coredns多副本运行在不同的机器上

corednes_yml=/tmp/k8s/coredns.yaml

kubectl get deployment coredns -n kube-system -o yaml > $corednes_yml

check_coredns_deploy=$( cat $corednes_yml  | grep podAntiAffinity | wc -l)
if [[ $check_coredns_deploy -gt "0" ]]; then
	echo "【SUCCESS】: coredns反亲和性已配置"
else

	spec_line=$(grep -n "spec:" $corednes_yml | cut -d: -f1 | awk 'NR==2' )
	
	if [ -n "$spec_line" ]; then
    # 插入内容到 "spec:" 行的下一行
    sed -i "${spec_line}a\\
      affinity: \\
        podAntiAffinity: \\
          preferredDuringSchedulingIgnoredDuringExecution: \\
          - weight: 1 \\
            podAffinityTerm: \\
              labelSelector: \\
                matchExpressions: \\
                - key: k8s-app \\
                  operator: In \\
                  values: \\
                  - kube-dns \\
              topologyKey: kubernetes.io/hostname" $corednes_yml
	
	    echo "内容已成功插入到 $corednes_yml 的 'spec:' 行下面。"
	else
	    echo "未找到 'spec:' 行。"
	fi

	kubectl apply -f $corednes_yml

	kubectl get deployment coredns -n kube-system -o yaml > $corednes_yml
	check_coredns_deploy=$( cat $corednes_yml  | grep podAntiAffinity | wc -l)
	if [[ $check_coredns_deploy -gt "0" ]]; then
		echo "【SUCCESS】: coredns反亲和性已配置"
	else
		echo "【ERROR】: coredns反亲和性配置失败，请手动检查"
	fi
fi



## =====================   16.安装metrics-server   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 16.安装metrics-server ====================="

kubectl apply -f /data/k8s_install/03.setup_file/metrics-server/metrics-server.yaml




## =====================   17.安装redis-sentinel   =====================##

echo "["$(date +"%Y-%m-%d %H:%M:%S")"] ===================== 17.安装redis-sentinel ====================="

kubectl create ns redis-sentinel
kubectl apply -f /data/k8s_install/03.setup_file/redis/redis-sentinel-pvc/redis-pv.yml
kubectl apply -f /data/k8s_install/03.setup_file/redis/redis-sentinel-pvc/storageclass.yml

/data/k8s_install/03.setup_file/redis/linux-arm64/helm install -n redis-sentinel redis-ha /data/k8s_install/03.setup_file/redis/allyaml/redis-ha
