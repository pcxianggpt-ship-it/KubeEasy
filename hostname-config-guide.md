# KubeEasy 主机名配置指南

## 🎯 功能概述

KubeEasy 优化版现在支持直接从 `config.yaml` 配置文件读取主机名设置，提供灵活的主机名管理功能。

## 🔧 主要改进

### 原版方式
```bash
# 硬编码的主机名生成逻辑
for m_ip in "${master_ips[@]}"; do
    ssh root@$m_ip "hostnamectl set-hostname k8sc$master_counter"
    master_counter=$((master_counter + 1))
done
```

### 优化版方式
```yaml
# 配置文件驱动
servers:
  master:
    - ip: "192.168.62.171"
      hostname: "k8sc1"    # 自定义主机名
    - ip: "192.168.62.172"
      hostname: "prod-master"  # 完全自定义
```

## 📋 支持的主机名配置方式

### 方式1：完全自定义主机名

```yaml
servers:
  master:
    - ip: "192.168.1.10"
      hostname: "production-master-01"
    - ip: "192.168.1.11"
      hostname: "production-master-02"

  workers:
    - ip: "192.168.1.20"
      hostname: "web-server-01"
    - ip: "192.168.1.21"
      hostname: "web-server-02"
```

**生成的主机名：**
- 192.168.1.10 → `production-master-01`
- 192.168.1.11 → `production-master-02`
- 192.168.1.20 → `web-server-01`
- 192.168.1.21 → `web-server-02`

### 方式2：部分自定义 + 自动生成

```yaml
servers:
  master:
    - ip: "192.168.1.10"
      hostname: "k8s-master"   # 自定义
    - ip: "192.168.1.11"        # 自动生成：k8sc2
    - ip: "192.168.1.12"        # 自动生成：k8sc3

  workers:
    - ip: "192.168.1.20"
      hostname: "k8s-worker"   # 自定义
    - ip: "192.168.1.21"        # 自动生成：k8sw2
    - ip: "192.168.1.22"        # 自动生成：k8sw3
```

**生成的主机名：**
- 192.168.1.10 → `k8s-master`
- 192.168.1.11 → `k8sc2`
- 192.168.1.12 → `k8sc3`
- 192.168.1.20 → `k8s-worker`
- 192.168.1.21 → `k8sw2`
- 192.168.1.22 → `k8sw3`

### 方式3：完全自动生成

```yaml
servers:
  master:
    - ip: "192.168.1.10"        # 自动生成：k8sc1
    - ip: "192.168.1.11"        # 自动生成：k8sc2
    - ip: "192.168.1.12"        # 自动生成：k8sc3

  workers:
    - ip: "192.168.1.20"        # 自动生成：k8sw1
    - ip: "192.168.1.21"        # 自动生成：k8sw2
    - ip: "192.168.1.22"        # 自动生成：k8sw3
```

**生成的主机名：**
- 192.168.1.10 → `k8sc1`
- 192.168.1.11 → `k8sc2`
- 192.168.1.12 → `k8sc3`
- 192.168.1.20 → `k8sw1`
- 192.168.1.21 → `k8sw2`
- 192.168.1.22 → `k8sw3`

## 🔍 技术实现

### 核心函数

#### 1. `read_yaml_value()` - YAML配置读取
```bash
# 优先使用 yq 工具，回退到简单grep解析
read_yaml_value <config_file> <yaml_path> <default_value>
```

#### 2. `parse_server_list()` - 服务器列表解析
```bash
# 解析指定类型的服务器列表
parse_server_list <config_file> <server_type>  # master, workers, registry
```

#### 3. `generate_hosts_content()` - hosts文件生成
```bash
# 自动生成完整的hosts文件内容
generate_hosts_content <config_file>
```

#### 4. `configure_hostname_hosts()` - 主配置函数
```bash
# 主要的主机名和hosts配置函数
configure_hostname_hosts
```

### 生成的hosts文件示例

```hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
192.168.1.10   production-master-01
192.168.1.11   production-master-02
192.168.1.20   web-server-01
192.168.1.21   web-server-02
192.168.1.30   registry
```

## 🚀 使用方法

### 基本使用

```bash
# 使用默认配置文件
./autoinstall-optimized.sh

# 使用自定义配置文件
./autoinstall-optimized.sh my-hostname-config.yaml
```

### 测试主机名配置

```bash
# 只执行主机名配置步骤
./autoinstall-optimized.sh --step hostname_hosts

# 使用测试配置文件
./autoinstall-optimized.sh example-hostname-config.yaml --step hostname_hosts
```

### 验证配置结果

```bash
# 检查生成的hosts文件
cat /tmp/kubeeasy_hosts_*

# 验证远程主机名
ssh root@192.168.1.10 "hostname"
ssh root@192.168.1.20 "hostname"

# 检查hosts文件
ssh root@192.168.1.10 "cat /etc/hosts"
```

## 📊 配置示例

### 生产环境配置

```yaml
servers:
  master:
    - ip: "10.0.1.10"
      hostname: "prod-k8s-master-01"
    - ip: "10.0.1.11"
      hostname: "prod-k8s-master-02"
    - ip: "10.0.1.12"
      hostname: "prod-k8s-master-03"

  workers:
    - ip: "10.0.1.20"
      hostname: "prod-app-node-01"
    - ip: "10.0.1.21"
      hostname: "prod-app-node-02"
    - ip: "10.0.1.22"
      hostname: "prod-app-node-03"
    - ip: "10.0.1.23"
      hostname: "prod-app-node-04"

  registry:
    - ip: "10.0.1.30"
      hostname: "prod-registry"
```

### 开发环境配置

```yaml
servers:
  master:
    - ip: "192.168.100.10"
      hostname: "dev-master"

  workers:
    - ip: "192.168.100.20"
      hostname: "dev-worker-01"
    - ip: "192.168.100.21"
      hostname: "dev-worker-02"
```

### 测试环境配置

```yaml
servers:
  master:
    - ip: "172.16.0.10"        # 自动生成：k8sc1

  workers:
    - ip: "172.16.0.20"        # 自动生成：k8sw1
    - ip: "172.16.0.21"        # 自动生成：k8sw2
    - ip: "172.16.0.22"        # 自动生成：k8sw3
```

## ⚠️ 注意事项

### 1. 主机名规范
- 长度限制：不超过 63 个字符
- 字符限制：只能包含字母、数字、连字符(-)
- 开头结尾：必须以字母或数字开头和结尾

### 2. 重复性检查
```bash
# 函数会自动检查并报告重复的主机名
# 如果发现重复，会在日志中警告并使用默认命名
```

### 3. 配置文件格式
```yaml
# 正确格式
servers:
  master:
    - ip: "192.168.1.10"
      hostname: "master-01"

# 错误格式（缺少缩进）
servers:
master:
    - ip: "192.168.1.10"
      hostname: "master-01"
```

### 4. 网络连通性
- 确保SSH免密登录已配置
- 确保所有节点网络连通
- 确保DNS解析正常

## 🐛 故障排查

### 常见问题

#### 1. 配置文件解析失败
```bash
# 检查YAML语法
yq eval . config.yaml

# 或使用在线YAML验证器
```

#### 2. 主机名设置失败
```bash
# 手动测试主机名设置
ssh root@192.168.1.10 "hostnamectl set-hostname test-host"

# 检查权限
ssh root@192.168.1.10 "whoami"
```

#### 3. hosts文件分发失败
```bash
# 手动测试文件分发
scp /tmp/hosts_test root@192.168.1.10:/tmp/hosts_test
```

### 调试模式

```bash
# 启用详细日志
export LOG_LEVEL=DEBUG
./autoinstall-optimized.sh --step hostname_hosts

# 检查日志
tail -f logs/install.log | grep "hostname"
```

## 📈 优势总结

1. **🔧 配置驱动**：主机名配置完全通过YAML文件管理
2. **🎯 灵活多样**：支持自定义、自动生成、混合模式
3. **📝 清晰明了**：配置文件结构清晰，易于理解和维护
4. **🛡️ 错误处理**：完善的错误检查和恢复机制
5. **📊 状态跟踪**：详细的配置进度和状态管理
6. **🔄 可扩展性**：易于扩展支持更多自定义选项

这个改进使得 KubeEasy 的主机名管理更加灵活、可配置和用户友好！