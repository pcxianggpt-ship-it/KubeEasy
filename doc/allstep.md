# KubeEasy 安装步骤文档

本文档记录 KubeEasy Kubernetes 集群安装的核心操作步骤。

---

## 第一阶段: check_system_environment - 系统环境检查

### 1. 控制节点执行的命令

本阶段在控制节点（第一个master节点）本地执行。

#### 1.1 检查必需的命令工具
```bash
# 检查 bash
command -v bash

# 检查 ssh
command -v ssh

# 检查 scp
command -v scp

# 检查 tar
command -v tar
```

#### 1.2 检查操作系统信息
```bash
# 检查操作系统类型
cat /etc/os-release | grep '^PRETTY_NAME='

# 检查系统架构
uname -m
```

#### 1.3 检查 root 权限
```bash
# 检查当前用户是否为 root
echo $EUID
# 应该返回 0 (表示 root)
```

#### 1.4 安装 yq 工具
```bash
# 获取系统架构
arch=$(uname -m)
# 根据架构设置类型
if [ "$arch" = "x86_64" ]; then
    arch_type="amd64"
elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
    arch_type="arm64"
fi

# 从本地工具目录安装 yq
cp tools/yq_linux_${arch_type} /usr/local/bin/yq
chmod +x /usr/local/bin/yq
```

#### 1.5 安装 helm 工具
```bash
# 获取系统架构
arch=$(uname -m)
# 根据架构设置 helm 需要的格式
if [ "$arch" = "x86_64" ]; then
    helm_arch="amd"
elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
    helm_arch="arm"
fi

# 从本地工具目录安装 helm
cp tools/helm-${helm_arch} /usr/local/bin/helm
chmod +x /usr/local/bin/helm
```

### 2. 工作节点执行的命令

本阶段不需要在工作节点执行任何命令。

### 3. 验证安装结果的命令

在控制节点执行以下命令验证环境检查是否成功：

```bash
# 验证 yq 工具已安装并显示版本
yq --version
# 预期输出: yq (version) ...

# 验证 helm 工具已安装并显示版本
helm version
# 预期输出: version.BuildInfo{...}

# 验证必需命令都可用
bash --version
ssh -V
scp -V
tar --version

# 验证系统架构
uname -m
# 预期输出: x86_64 或 aarch64

# 验证当前用户
whoami
# 预期输出: root
```

### 预期结果

- ✅ 所有必需的命令工具(bash, ssh, scp, tar)都已安装
- ✅ 操作系统信息正常显示
- ✅ 系统架构为 x86_64 或 aarch64
- ✅ 当前用户具有 root 权限
- ✅ yq 工具已成功安装并可执行
- ✅ helm 工具已成功安装并可执行

### 故障排查

如果 yq 或 helm 安装失败：

1. 检查工具文件是否存在：
   ```bash
   ls -l tools/yq_linux_*
   ls -l tools/helm-*
   ```

2. 检查文件权限：
   ```bash
   ls -l /usr/local/bin/yq
   ls -l /usr/local/bin/helm
   ```

3. 手动安装（如果自动安装失败）：
   ```bash
   # 从官方网站下载并安装 yq
   # 或从 tools 目录手动复制
   ```

---

## 第二阶段: load_config - 加载配置文件

### 1. 控制节点执行的命令

本阶段在控制节点（第一个master节点）本地执行，主要用于读取和解析 config.yaml 配置文件。

#### 1.1 检查配置文件存在
```bash
# 检查配置文件是否存在
test -f config.yaml

# 查看配置文件内容
cat config.yaml
```

#### 1.2 检查 yq 工具可用性
```bash
# 检查 yq 工具是否安装
command -v yq

# 查看 yq 版本
yq --version
```

#### 1.3 获取系统架构
```bash
# 获取系统架构
arch=$(uname -m)
echo "系统架构: $arch"

# 根据架构设置类型
if [ "$arch" = "x86_64" ]; then
    arch_type="amd64"
elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
    arch_type="arm64"
fi
echo "架构类型: $arch_type"
```

#### 1.4 加载基本路径配置
```bash
# 使用 yq 读取配置文件中的基本路径
data_path=$(yq eval '.system.data_path // "/data/k8s_install"' config.yaml | tr -d '"')
work_dir=$(yq eval '.system.work_dir // "/data"' config.yaml | tr -d '"')

echo "data_path: $data_path"
echo "work_dir: $work_dir"
```

#### 1.5 加载镜像仓库配置
```bash
# 读取镜像仓库相关配置
registry_ip=$(yq eval '.registry.ip' config.yaml | tr -d '"')
registry_port=$(yq eval '.registry.port' config.yaml | tr -d '"')
registry_user=$(yq eval '.registry.username' config.yaml | tr -d '"')
registry_passwd=$(yq eval '.registry.password' config.yaml | tr -d '"')
registry_auth=$(yq eval '.registry.auth // "no"' config.yaml 2>/dev/null | tr -d '"')

echo "registry_ip: $registry_ip"
echo "registry_port: $registry_port"
echo "registry_user: $registry_user"
echo "registry_auth: $registry_auth"
```

#### 1.6 加载系统配置
```bash
# 读取 DNS 和节点密码配置
dns_ip=$(yq eval '.system.dns_servers[0] // "192.168.62.1"' config.yaml | tr -d '"')
node_password=$(yq eval '.system.node_password // ""' config.yaml | tr -d '"')

echo "dns_ip: $dns_ip"
echo "node_password: [已设置]"
```

#### 1.7 加载 Kubernetes 集群配置
```bash
# 读取 K8s 版本和网络配置
k8s_version=$(yq eval '.cluster.version' config.yaml | tr -d '"')
k8s_pod_subnet=$(yq eval '.network.pod_subnet // "10.244.0.0/16"' config.yaml | tr -d '"')
k8s_service_subnet=$(yq eval '.network.service_subnet // "10.96.0.0/12"' config.yaml | tr -d '"')
DUAL_STACK=$(yq eval '.cluster.dualStack // "N"' config.yaml | tr -d '"')

echo "k8s_version: $k8s_version"
echo "k8s_pod_subnet: $k8s_pod_subnet"
echo "k8s_service_subnet: $k8s_service_subnet"
echo "DUAL_STACK: $DUAL_STACK"
```

#### 1.8 加载存储配置
```bash
# 读取 NFS 存储配置
nfs_enable=$(yq eval '.storage.nfs.enable // "false"' config.yaml 2>/dev/null | tr -d '"')
nfs_server_ip=$(yq eval '.storage.nfs.server_ip' config.yaml 2>/dev/null | tr -d '"')
nfs_path=$(yq eval '.storage.nfs.path // "/data/nfs_root"' config.yaml 2>/dev/null | tr -d '"')
storage_class=$(yq eval '.storage.storage_class // "nfs-client"' config.yaml 2>/dev/null | tr -d '"')

echo "nfs_enable: $nfs_enable"
echo "nfs_server_ip: $nfs_server_ip"
echo "nfs_path: $nfs_path"
echo "storage_class: $storage_class"
```

#### 1.9 解析控制节点配置
```bash
# 读取控制节点数量和配置
master_count=$(yq eval '.servers.master | length' config.yaml)
echo "控制节点数量: $master_count"

# 遍历所有控制节点
for ((i=0; i<master_count; i++)); do
    ip=$(yq eval ".servers.master[$i].ip" config.yaml)
    hostname=$(yq eval ".servers.master[$i].hostname" config.yaml | tr -d '"')
    ipv6_addr=$(yq eval ".servers.master[$i].ipv6_addr // \"\"" config.yaml 2>/dev/null | tr -d '"')

    echo "Master $((i+1)): IP=$ip, Hostname=$hostname, IPv6=$ipv6_addr"
done
```

#### 1.10 解析工作节点配置
```bash
# 读取工作节点数量和配置
worker_count=$(yq eval '.servers.workers | length' config.yaml)
echo "工作节点数量: $worker_count"

# 遍历所有工作节点
for ((i=0; i<worker_count; i++)); do
    ip=$(yq eval ".servers.workers[$i].ip" config.yaml)
    hostname=$(yq eval ".servers.workers[$i].hostname" config.yaml | tr -d '"')
    ipv6_addr=$(yq eval ".servers.workers[$i].ipv6_addr // \"\"" config.yaml 2>/dev/null | tr -d '"')

    echo "Worker $((i+1)): IP=$ip, Hostname=$hostname, IPv6=$ipv6_addr"
done
```

#### 1.11 解析镜像仓库节点配置
```bash
# 读取镜像仓库节点数量和配置
registry_count=$(yq eval '.servers.registry | length' config.yaml)
echo "镜像仓库节点数量: $registry_count"

# 遍历所有镜像仓库节点
for ((i=0; i<registry_count; i++)); do
    ip=$(yq eval ".servers.registry[$i].ip" config.yaml)
    hostname=$(yq eval ".servers.registry[$i].hostname" config.yaml | tr -d '"')
    ipv6_addr=$(yq eval ".servers.registry[$i].ipv6_addr // \"\"" config.yaml 2>/dev/null | tr -d '"')

    echo "Registry $((i+1)): IP=$ip, Hostname=$hostname, IPv6=$ipv6_addr"
done
```

#### 1.12 获取第一个 master 节点 IP
```bash
# 获取第一个 master 节点的 IP（k8sc1）
k8sc1_ip=$(yq eval '.servers.master[0].ip' config.yaml | tr -d '"')
echo "k8sc1_ip: $k8sc1_ip"
```

### 2. 工作节点执行的命令

本阶段不需要在工作节点执行任何命令。

### 3. 验证加载结果的命令

在控制节点执行以下命令验证配置是否成功加载：

```bash
# 验证环境变量已导出
echo "=== 系统配置 ==="
echo "arch: $arch"
echo "arch_type: $arch_type"

echo -e "\n=== 路径配置 ==="
echo "data_path: $data_path"
echo "work_dir: $work_dir"

echo -e "\n=== 镜像仓库配置 ==="
echo "registry_ip: $registry_ip"
echo "registry_port: $registry_port"

echo -e "\n=== DNS 配置 ==="
echo "dns_ip: $dns_ip"

echo -e "\n=== K8s 配置 ==="
echo "k8s_version: $k8s_version"
echo "k8s_pod_subnet: $k8s_pod_subnet"
echo "k8s_service_subnet: $k8s_service_subnet"
echo "DUAL_STACK: $DUAL_STACK"
echo "k8sc1_ip: $k8sc1_ip"

echo -e "\n=== 节点统计 ==="
echo "控制节点数: ${#master_ips[@]}"
echo "工作节点数: ${#worker_ips[@]}"
echo "镜像仓库节点数: ${#registry_ips[@]}"
echo "K8S 总节点数: ${#k8s_nodes[@]}"
echo "所有节点数: ${#all_nodes[@]}"

echo -e "\n=== 控制节点列表 ==="
for ip in "${master_ips[@]}"; do
    hostname="${master_hostnames[$ip]}"
    echo "  $ip -> $hostname"
done

echo -e "\n=== 工作节点列表 ==="
for ip in "${worker_ips[@]}"; do
    hostname="${worker_hostnames[$ip]}"
    echo "  $ip -> $hostname"
done

echo -e "\n=== 镜像仓库节点列表 ==="
for ip in "${registry_ips[@]}"; do
    hostname="${registry_hostnames[$ip]}"
    echo "  $ip -> $hostname"
done

echo -e "\n=== 存储配置 ==="
echo "NFS 启用: $nfs_enable"
echo "NFS 服务器: $nfs_server_ip"
echo "NFS 路径: $nfs_path"
echo "存储类: $storage_class"
```

### 预期结果

- ✅ 配置文件 config.yaml 存在且可读
- ✅ yq 工具已安装并可执行
- ✅ 系统架构识别成功 (x86_64 或 aarch64)
- ✅ 所有配置变量成功加载
- ✅ 节点数组初始化完成
  - master_ips 数组包含所有控制节点 IP
  - worker_ips 数组包含所有工作节点 IP
  - registry_ips 数组包含所有镜像仓库节点 IP
  - k8s_nodes 数组包含所有 K8s 节点 IP
  - all_nodes 数组包含所有节点 IP
- ✅ 主机名映射数组初始化完成
- ✅ IPv6 地址映射数组初始化完成（如果配置了双栈网络）

### 故障排查

如果配置加载失败：

1. 检查配置文件是否存在：
   ```bash
   ls -l config.yaml
   cat config.yaml
   ```

2. 检查 yq 工具是否可用：
   ```bash
   which yq
   yq --version
   ```

3. 手动测试 yq 读取配置：
   ```bash
   # 测试读取基本配置
   yq eval '.system' config.yaml
   yq eval '.cluster' config.yaml
   yq eval '.servers' config.yaml
   ```

4. 检查配置文件格式是否正确：
   ```bash
   # 验证 YAML 语法
   python3 -c "import yaml; yaml.safe_load(open('config.yaml'))"
   ```

5. 检查必需字段是否存在：
   ```bash
   # 检查必需的顶级字段
   yq eval 'keys' config.yaml

   # 检查 servers 配置
   yq eval '.servers.master | length' config.yaml
   yq eval '.servers.workers | length' config.yaml
   yq eval '.servers.registry | length' config.yaml
   ```

6. 查看详细日志：
   ```bash
   cat logs/install.log | grep "加载配置"
   ```

---

## 第三阶段: configure_k8srepo_server - 配置本地yum源

### 1. 控制节点执行的命令

本阶段在控制节点（第一个master节点）本地执行，配置本地YUM源服务器。

#### 1.1 检查YUM源包文件
```bash
# 检查YUM源tar包是否存在（路径从config.yaml读取）
ls -l $data_path/01.rpm_package/k8srepo_kylinos_sp3_amd.tar.gz

# 查看文件大小和详细信息
du -sh $data_path/01.rpm_package/k8srepo_kylinos_sp3_amd.tar.gz
file $data_path/01.rpm_package/k8srepo_kylinos_sp3_amd.tar.gz
```

#### 1.2 执行YUM源配置

```bash
# 设置YUM源tar包路径（从config.yaml读取）
repo_source_name="$data_path/01.rpm_package/k8srepo_kylinos_sp3_amd.tar.gz"

# 1. 创建HTTP服务目录并解压YUM源包
mkdir -p /var/www/html/
tar -zxf $repo_source_name -C /var/www/html/

# 2. 创建本地YUM仓库配置文件 /etc/yum.repos.d/k8s.repo
cat > /etc/yum.repos.d/k8s.repo << EOF
[k8s-yum]
name=rhel7
baseurl=file:///var/www/html/repo/
enabled=1
gpgcheck=0
EOF

# 3. 刷新YUM缓存
yum clean all
yum makecache

# 4. 安装httpd服务
yum -y install httpd

# 5. 启动httpd服务并设置开机自启
systemctl enable httpd --now

# 6. 关闭防火墙
systemctl stop firewalld
systemctl disable firewalld
```

### 2. 工作节点执行的命令

本阶段不需要在工作节点执行命令（工作节点的YUM客户端配置在下一步）。

### 3. 验证安装结果的命令

在控制节点执行以下命令验证YUM源配置是否成功：

```bash
# 1. 验证httpd服务状态
systemctl status httpd
netstat -tlnp | grep :80

# 2. 验证防火墙状态
systemctl status firewalld

# 3. 检查YUM仓库配置文件是否存在
ls -l /etc/yum.repos.d/k8s.repo
cat /etc/yum.repos.d/k8s.repo

# 4. 查看YUM仓库列表
yum repolist

# 5. 最终验证yum源 - 搜索k8s相关包
yum search kubelet
yum info kubeadm | head -10
yum info kubectl | head -10
yum search kubeadm

# 6. 检查仓库目录内容
ls -l /var/www/html/repo/

# 7. 测试YUM源可用性
yum list available | grep kubernetes
```

### 预期结果

- ✅ YUM源tar包成功解压到 /var/www/html/
- ✅ 本地YUM仓库配置文件 /etc/yum.repos.d/k8s.repo 创建成功
- ✅ httpd服务启动并监听端口80
- ✅ 防火墙已关闭并禁用开机自启
- ✅ `yum repolist` 命令可以查看到 k8s-yum 仓库
- ✅ 可以搜索到 kubelet、kubeadm、kubectl 等K8s相关包
- ✅ `yum info` 命令可以显示包的详细信息

### 故障排查

如果YUM源配置失败：

1. 检查YUM源tar包是否存在：
   ```bash
   ls -l $data_path/01.rpm_package/k8srepo_kylinos_sp3_amd.tar.gz
   file $data_path/01.rpm_package/k8srepo_kylinos_sp3_amd.tar.gz
   du -sh $data_path/01.rpm_package/k8srepo_kylinos_sp3_amd.tar.gz
   ```

2. 检查httpd服务状态：
   ```bash
   systemctl status httpd
   journalctl -u httpd -n 50
   ```

3. 检查端口占用：
   ```bash
   netstat -tlnp | grep :80
   ss -tlnp | grep :80
   lsof -i :80
   ```

4. 检查YUM仓库配置文件：
   ```bash
   ls -l /etc/yum.repos.d/k8s.repo
   cat /etc/yum.repos.d/k8s.repo
   ```

5. 检查仓库目录内容：
   ```bash
   ls -l /var/www/html/
   ls -l /var/www/html/repo/
   ```

6. 测试HTTP访问：
   ```bash
   curl -I http://localhost/
   curl http://localhost/repo/ | head -20
   ```

7. 重新加载YUM缓存：
   ```bash
   yum clean all
   yum makecache
   ```

8. 测试YUM源：
   ```bash
   yum repolist
   yum search kubelet
   yum info kubeadm
   ```

9. 检查防火墙状态：
   ```bash
   systemctl status firewalld
   firewall-cmd --list-all
   ```

10. 检查SELinux状态：
    ```bash
    getenforce
    # 如果是Enforcing，可能需要临时设置为Permissive
    setenforce 0
    ```

---

## 第四阶段: setup_ssh_keyless - 配置SSH免密登录

### 1. 控制节点执行的命令

本阶段在控制节点（第一个master节点）本地执行，配置SSH免密登录到所有其他节点。

#### 1.1 检查节点密码配置
```bash
# 检查是否已配置节点密码（从config.yaml读取）
echo "node_password: $node_password"

# 如果未设置，配置文件中应该包含 .system.node_password 字段
# 或需要手动输入密码进行交互式配置
```

#### 1.2 安装sshpass工具
```bash
# 检查sshpass是否已安装
command -v sshpass

# 如果未安装，使用包管理器安装
# CentOS/RHEL系统
yum install -y sshpass

# Ubuntu/Debian系统
apt-get update && apt-get install -y sshpass

# 验证安装
sshpass -V
```

#### 1.3 检查并生成SSH密钥对
```bash
# 检查SSH密钥是否已存在
ls -l ~/.ssh/id_rsa
ls -l ~/.ssh/id_rsa.pub

# 如果不存在，生成新的SSH密钥对
ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""

# 验证密钥生成成功
cat ~/.ssh/id_rsa.pub
```

#### 1.4 配置本地SSH配置文件
```bash
# 创建SSH配置文件，禁用主机密钥检查
cat > ~/.ssh/config << 'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
    LogLevel=ERROR
EOF

# 设置正确的权限
chmod 600 ~/.ssh/config

# 验证配置
cat ~/.ssh/config
```

#### 1.5 分发SSH公钥到所有节点

使用配置的密码自动分发公钥：

```bash
# 方法1：使用sshpass自动分发（推荐）
# 假设 node_password 已在 config.yaml 中配置

# 对每个节点执行公钥分发
for server_ip in "${all_nodes[@]}"; do
    echo "分发公钥到节点: $server_ip"

    # 使用sshpass和ssh-copy-id
    sshpass -p "$node_password" ssh-copy-id -i ~/.ssh/id_rsa.pub root@"$server_ip"

    # 测试免密登录
    ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$server_ip" "hostname && date"
done
```

或使用expect脚本自动分发：

```bash
# 方法2：使用expect脚本自动分发
# 创建临时expect脚本
cat > /tmp/ssh_copy.exp << EOF
#!/usr/bin/expect -f
set server_ip [lindex \$argv 0]
set password [lindex \$argv 1]

spawn ssh-copy-id -i ~/.ssh/id_rsa.pub root@\$server_ip
expect {
    "yes/no" { send "yes\r"; exp_continue }
    "password:" { send "\$password\r"; exp_continue }
    eof
}
EOF

chmod +x /tmp/ssh_copy.exp

# 对每个节点执行
for server_ip in "${all_nodes[@]}"; do
    /tmp/ssh_copy.exp "$server_ip" "$node_password"
done

# 清理临时文件
rm -f /tmp/ssh_copy.exp
```

或手动复制公钥内容：

```bash
# 方法3：手动复制公钥内容
# 读取公钥内容
ssh_key_content=$(cat ~/.ssh/id_rsa.pub)

# 对每个节点执行
for server_ip in "${all_nodes[@]}"; do
    echo "配置节点: $server_ip"

    # 使用sshpass直接SSH并添加公钥
    sshpass -p "$node_password" ssh -o StrictHostKeyChecking=no root@"$server_ip" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

    sshpass -p "$node_password" ssh -o StrictHostKeyChecking=no root@"$server_ip" \
        "echo '$ssh_key_content' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

    # 测试免密登录
    ssh -o BatchMode=yes root@"$server_ip" "hostname"
done
```

#### 1.6 配置节点间相互免密登录

为了让所有节点之间都能相互SSH免密登录：

```bash
# 在每个节点上配置其他节点的公钥
for server_ip in "${all_nodes[@]}"; do
    echo "在节点 $server_ip 配置其他节点的SSH访问"

    # 将其他节点的公钥添加到当前节点
    for other_ip in "${all_nodes[@]}"; do
        if [ "$server_ip" != "$other_ip" ]; then
            # 获取其他节点的公钥
            remote_pubkey=$(ssh root@"$other_ip" "cat ~/.ssh/id_rsa.pub" 2>/dev/null)

            if [ -n "$remote_pubkey" ]; then
                # 添加到当前节点的authorized_keys
                ssh root@"$server_ip" "echo '$remote_pubkey' >> ~/.ssh/authorized_keys"
            fi
        fi
    done

    # 确保权限正确
    ssh root@"$server_ip" "chmod 600 ~/.ssh/authorized_keys"
done
```

### 2. 工作节点执行的命令

本阶段不需要在工作节点手动执行命令，所有配置都通过控制节点SSH到工作节点完成。

但是，可以在工作节点上验证配置是否成功：

```bash
# 在任意工作节点上执行
# 查看authorized_keys文件
cat ~/.ssh/authorized_keys

# 查看SSH密钥对
ls -l ~/.ssh/

# 测试SSH配置
cat ~/.ssh/config
```

### 3. 验证安装结果的命令

在控制节点执行以下命令验证SSH免密登录配置是否成功：

```bash
# 1. 验证本地SSH密钥对存在
echo "=== 检查本地SSH密钥 ==="
ls -l ~/.ssh/id_rsa
ls -l ~/.ssh/id_rsa.pub
echo "公钥内容:"
cat ~/.ssh/id_rsa.pub

echo -e "\n=== 检查SSH配置文件 ==="
cat ~/.ssh/config

# 2. 测试从控制节点到所有其他节点的免密登录
echo -e "\n=== 测试SSH免密登录 ==="
for server_ip in "${all_nodes[@]}"; do
    echo -n "测试节点 $server_ip: "

    if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$server_ip" "echo 'Success'" 2>/dev/null; then
        echo "✓ 成功"
    else
        echo "✗ 失败"
    fi
done

# 3. 验证能获取远程节点主机名和时间
echo -e "\n=== 验证远程节点信息 ==="
for server_ip in "${all_nodes[@]}"; do
    echo "--- 节点: $server_ip ---"
    ssh root@"$server_ip" "hostname && date && uname -a"
done

# 4. 验证能执行远程命令
echo -e "\n=== 测试远程命令执行 ==="
for server_ip in "${all_nodes[@]}"; do
    echo "节点 $server_ip 的系统信息:"
    ssh root@"$server_ip" "df -h | head -5"
done

# 5. 测试节点间相互SSH（从控制节点发起）
echo -e "\n=== 测试节点间相互访问（通过控制节点）==="
for server_ip in "${all_nodes[@]}"; do
    for other_ip in "${all_nodes[@]}"; do
        if [ "$server_ip" != "$other_ip" ]; then
            echo -n "从 $server_ip 到 $other_ip: "

            if ssh root@"$server_ip" "ssh -o BatchMode=yes -o ConnectTimeout=3 root@$other_ip 'echo Success'" 2>/dev/null; then
                echo "✓ 成功"
            else
                echo "✗ 失败"
            fi
        fi
    done
done

# 6. 检查sshpass工具
echo -e "\n=== 检查sshpass工具 ==="
which sshpass
sshpass -V

# 7. 验证所有节点的authorized_keys配置
echo -e "\n=== 检查节点authorized_keys ==="
for server_ip in "${all_nodes[@]}"; do
    echo "--- 节点: $server_ip ---"
    ssh root@"$server_ip" "ls -l ~/.ssh/authorized_keys && wc -l ~/.ssh/authorized_keys"
done
```

### 预期结果

- ✅ sshpass工具已成功安装
- ✅ SSH密钥对已生成（id_rsa 和 id_rsa.pub）
- ✅ SSH配置文件已创建并配置正确权限
- ✅ 控制节点可以免密登录到所有其他节点
- ✅ 所有节点间可以相互SSH免密登录
- ✅ 使用 `ssh -o BatchMode=yes` 可以成功执行远程命令
- ✅ 每个节点的 `~/.ssh/authorized_keys` 文件包含其他所有节点的公钥
- ✅ 所有authorized_keys文件权限为600
- ✅ SSH连接不需要输入密码或确认yes/no

### 故障排查

如果SSH免密登录配置失败：

1. 检查SSH密钥是否生成：
   ```bash
   ls -l ~/.ssh/id_rsa*
   file ~/.ssh/id_rsa
   ```

2. 手动生成SSH密钥（如果自动生成失败）：
   ```bash
   # 删除旧密钥（如果有问题）
   rm -f ~/.ssh/id_rsa ~/.ssh/id_rsa.pub

   # 重新生成
   ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""
   ```

3. 检查并修复SSH配置文件：
   ```bash
   cat ~/.ssh/config
   chmod 600 ~/.ssh/config
   ```

4. 测试SSH连接（不使用BatchMode查看详细错误）：
   ```bash
   ssh -v root@<节点IP> "hostname"
   ```

5. 手动测试ssh-copy-id：
   ```bash
   # 交互式测试
   ssh-copy-id -i ~/.ssh/id_rsa.pub root@<节点IP>

   # 输入密码后测试免密登录
   ssh root@<节点IP> "hostname"
   ```

6. 检查远程节点的SSH配置：
   ```bash
   # 在远程节点上检查
   ssh root@<节点IP> "ls -la ~/.ssh/"
   ssh root@<节点IP> "cat ~/.ssh/authorized_keys"
   ssh root@<节点IP> "cat /etc/ssh/sshd_config | grep -E 'PubkeyAuthentication|AuthorizedKeysFile'"
   ```

7. 检查SSH服务状态：
   ```bash
   # 在远程节点上检查SSH服务
   ssh root@<节点IP> "systemctl status sshd"
   ssh root@<节点IP> "journalctl -u sshd -n 20"
   ```

8. 检查防火墙和SSH端口：
   ```bash
   # 确保SSH端口22开放
   netstat -tlnp | grep :22
   firewall-cmd --list-ports | grep 22
   ```

9. 重置远程节点的SSH配置（如果权限问题）：
   ```bash
   # 通过密码登录到远程节点执行
   ssh root@<节点IP> << 'EOF'
   # 修复.ssh目录权限
   chmod 700 ~/.ssh
   chmod 600 ~/.ssh/authorized_keys
   # 确保公钥认证启用
   sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
   sed -i 's/^#*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' /etc/ssh/sshd_config
   # 重启SSH服务
   systemctl restart sshd
   EOF
   ```

10. 查看详细日志：
    ```bash
    cat logs/install.log | grep "SSH免密登录"
    cat logs/install.log | grep "ssh_keyless"
    ```

11. 检查密码是否正确：
    ```bash
    # 手动测试密码登录
    sshpass -p "$node_password" ssh -o StrictHostKeyChecking=no root@<节点IP> "echo 'Password login works'"
    ```

12. 测试expect脚本（如果使用）：
    ```bash
    # 检查expect是否安装
    which expect
    expect -v

    # 手动运行expect脚本调试
    expect -d /tmp/ssh_copy.exp <节点IP> <密码>
    ```

---

## 第五阶段: configure_k8srepo_client - 配置本地k8s repo源客户端

### 1. 控制节点执行的命令

本阶段在控制节点执行，为其他所有节点（除控制节点外）配置YUM客户端，使其能够使用控制节点上的本地YUM源。

#### 1.1 检查YUM客户端脚本
```bash
# 检查YUM客户端配置脚本是否存在
ls -l installscript/01.yum_client.sh

# 查看脚本内容
cat installscript/01.yum_client.sh
```

#### 1.2 识别需要配置的客户端节点
```bash
# 确定registry服务器IP（用于HTTP访问YUM源）
echo "Registry IP: ${registry_ips[0]}"
echo "控制节点IP: $k8sc1_ip"

# 识别需要配置YUM客户端的节点（除k8sc1外的所有节点）
client_nodes=()
for node_ip in "${all_nodes[@]}"; do
    if [ "$node_ip" != "$k8sc1_ip" ]; then
        client_nodes+=("$node_ip")
    fi
done

echo "需要配置YUM客户端的节点数量: ${#client_nodes[@]}"
echo "客户端节点: ${client_nodes[@]}"
```

#### 1.3 分发并执行YUM客户端配置脚本

方法1：通过SSH执行远程脚本（推荐）：

```bash
# 对每个客户端节点执行YUM客户端配置脚本
for client_ip in "${client_nodes[@]}"; do
    echo "在节点 $client_ip 配置YUM客户端"

    # 使用SSH执行远程脚本（参数：registry IP）
    ssh root@"$client_ip" "bash -s" < installscript/01.yum_client.sh "${registry_ips[0]}"

    # 验证脚本执行是否成功
    if [ $? -eq 0 ]; then
        echo "✓ YUM客户端配置成功: $client_ip"
    else
        echo "✗ YUM客户端配置失败: $client_ip"
    fi
done
```

方法2：先分发脚本再执行：

```bash
# 复制脚本到所有客户端节点
for client_ip in "${client_nodes[@]}"; do
    echo "分发脚本到节点: $client_ip"

    # 创建临时目录
    ssh root@"$client_ip" "mkdir -p /tmp/k8s_install"

    # 复制脚本
    scp installscript/01.yum_client.sh root@"$client_ip":/tmp/k8s_install/

    # 执行脚本
    ssh root@"$client_ip" "bash /tmp/k8s_install/01.yum_client.sh ${registry_ips[0]}"
done
```

#### 1.4 脚本内部执行的主要操作

实际执行的 `installscript/01.yum_client.sh` 脚本会在每个客户端节点执行以下操作：

```bash
# 1. 创建YUM仓库配置文件 /etc/yum.repos.d/k8s-http.repo
cat > /etc/yum.repos.d/k8s-http.repo << EOF
[k8s-repo]
name=http
baseurl=http://${registry_ips[0]}/repo
enabled=1
gpgcheck=0
EOF

# 2. 清理YUM缓存
yum clean all

# 3. 重建YUM缓存
yum makecache
```

### 2. 工作节点执行的命令

本阶段不需要在工作节点手动执行命令，所有配置都通过控制节点SSH到工作节点完成。

但是，可以在工作节点上验证配置：

```bash
# 在任意工作节点上执行验证

# 检查k8s-http.repo配置文件
cat /etc/yum.repos.d/k8s-http.repo

# 查看YUM仓库列表
yum repolist

# 搜索k8s相关包
yum search kubelet
yum search kubeadm
yum search kubectl
```

### 3. 验证安装结果的命令

在控制节点执行以下命令验证YUM客户端配置是否成功：

```bash
# 1. 验证所有客户端节点的k8s-http.repo文件是否存在
echo "=== 检查YUM配置文件 ==="
for client_ip in "${client_nodes[@]}"; do
    echo "--- 节点: $client_ip ---"
    ssh root@"$client_ip" "cat /etc/yum.repos.d/k8s-http.repo"
done

# 2. 验证YUM仓库列表
echo -e "\n=== 验证YUM仓库列表 ==="
for client_ip in "${client_nodes[@]}"; do
    echo "--- 节点: $client_ip ---"
    ssh root@"$client_ip" "yum repolist | grep k8s-repo"
done

# 3. 搜索k8s相关包
echo -e "\n=== 搜索kubelet包 ==="
for client_ip in "${client_nodes[@]}"; do
    echo "--- 节点: $client_ip ---"
    search_result=$(ssh root@"$client_ip" "yum search kubelet 2>/dev/null")

    if echo "$search_result" | grep -q "kubelet"; then
        echo "✓ 找到kubelet包"
        echo "$search_result" | head -5
    else
        echo "✗ 未找到kubelet包"
    fi
done

# 4. 验证kubeadm和kubectl
echo -e "\n=== 搜索kubeadm和kubectl ==="
for client_ip in "${client_nodes[@]}"; do
    echo "--- 节点: $client_ip ---"

    if ssh root@"$client_ip" "yum info kubeadm 2>/dev/null | grep -q 'Name'"; then
        echo "✓ kubeadm: 可用"
    else
        echo "✗ kubeadm: 不可用"
    fi

    if ssh root@"$client_ip" "yum info kubectl 2>/dev/null | grep -q 'Name'"; then
        echo "✓ kubectl: 可用"
    else
        echo "✗ kubectl: 不可用"
    fi
done

# 5. 测试HTTP访问YUM源
echo -e "\n=== 测试HTTP访问YUM源 ==="
for client_ip in "${client_nodes[@]}"; do
    echo "--- 节点: $client_ip ---"
    if ssh root@"$client_ip" "curl -s -o /dev/null -w '%{http_code}' http://${registry_ips[0]}/repo/ | grep -q '200'"; then
        echo "✓ HTTP访问成功"
    else
        echo "✗ HTTP访问失败"
    fi
done

# 6. 验证YUM缓存
echo -e "\n=== 检查YUM缓存 ==="
for client_ip in "${client_nodes[@]}"; do
    echo "--- 节点: $client_ip ---"
    ssh root@"$client_ip" "ls -lh /var/cache/yum/ | head -10"
done
```

### 预期结果

- ✅ 所有客户端节点都有 `/etc/yum.repos.d/k8s-http.repo` 配置文件
- ✅ 配置文件中的 baseurl 指向 `http://<registry_ip>/repo`
- ✅ `yum repolist` 命令可以查看到 k8s-repo 仓库
- ✅ 可以搜索到 kubelet、kubeadm、kubectl 等K8s相关包
- ✅ `yum info` 命令可以显示包的详细信息
- ✅ YUM缓存已成功创建
- ✅ HTTP可以访问到YUM源服务器

### 故障排查

如果YUM客户端配置失败：

1. 检查客户端脚本是否存在：
   ```bash
   ls -l installscript/01.yum_client.sh
   cat installscript/01.yum_client.sh
   ```

2. 检查网络连通性：
   ```bash
   # 在客户端节点测试到YUM源服务器的网络
   for client_ip in "${client_nodes[@]}"; do
       echo "测试节点: $client_ip"
       ssh root@"$client_ip" "ping -c 3 ${registry_ips[0]}"
       ssh root@"$client_ip" "curl -I http://${registry_ips[0]}/repo/"
   done
   ```

3. 手动在客户端节点创建配置文件：
   ```bash
   # 在客户端节点上执行
   cat > /etc/yum.repos.d/k8s-http.repo << 'EOF'
   [k8s-repo]
   name=http
   baseurl=http://<registry_ip>/repo
   enabled=1
   gpgcheck=0
   EOF

   # 清理并重建缓存
   yum clean all
   yum makecache
   ```

4. 检查防火墙设置：
   ```bash
   # 在YUM源服务器上检查HTTP端口
   firewall-cmd --list-ports | grep 80
   netstat -tlnp | grep :80

   # 在客户端节点测试端口
   for client_ip in "${client_nodes[@]}"; do
       ssh root@"$client_ip" "telnet ${registry_ips[0]} 80"
   done
   ```

5. 检查YUM源服务器状态：
   ```bash
   # 在YUM源服务器（registry节点）上检查
   systemctl status nginx
   # 或
   systemctl status httpd

   # 检查repo目录
   ls -l /data/k8srepo/
   ```

6. 手动测试yum命令：
   ```bash
   # 在客户端节点上
   ssh root@<client_ip>

   # 详细模式运行yum
   yum -v search kubelet

   # 查看repo配置
   yum repolist -v

   # 查看debug信息
   yum --debuglevel=2 search kubelet
   ```

7. 检查SELinux状态：
   ```bash
   # 在客户端节点上
   ssh root@<client_ip> "getenforce"

   # 如果是Enforcing，临时测试
   ssh root@<client_ip> "setenforce 0"
   ssh root@<client_ip> "yum clean all && yum makecache"
   ```

8. 查看详细日志：
   ```bash
   cat logs/install.log | grep "配置本地k8s repo客户端"
   cat logs/install.log | grep "YUM客户端"
   ```

9. 手动执行脚本查看输出：
   ```bash
   # 在客户端节点上手动执行
   ssh root@<client_ip>
   bash -x installscript/01.yum_client.sh <registry_ip>
   ```

10. 验证HTTP响应内容：
    ```bash
    # 在客户端节点上查看YUM源HTTP响应
    ssh root@<client_ip> "curl http://${registry_ips[0]}/repo/ | head -20"
    ```

---


