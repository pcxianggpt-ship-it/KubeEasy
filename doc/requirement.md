# KubeEasy 自动化安装需求文档

## 项目概述

KubeEasy 是一个 Kubernetes 集群自动化安装部署工具，旨在通过主控脚本串联多个安装脚本，实现全自动化、跨服务器的 K8s 集群部署。

## 版本支持策略

### Kubernetes 版本选择
- **支持版本**：仅支持 **v1.23.17** 和 **v1.30.14** 两个版本
- **版本兼容性**：
  - **Kubernetes v1.23.17**：默认使用 **Docker 20.10.24** 作为容器运行时
  - **Kubernetes v1.30.14**：默认使用 **Containerd 1.7.18** 作为容器运行时

### 容器运行时版本映射
| K8s 版本 | 默认容器运行时 | 版本 | 说明 |
|----------|---------------|------|------|
| v1.23.17 | Docker | 20.10.24 | 稳定版本，Docker支持 |
| v1.30.14 | Containerd | 1.7.18 | 最新版本，Containerd支持 |

### 版本选择策略
1. **生产环境**：推荐使用 v1.23.17 + Docker（稳定性优先）
2. **测试环境**：推荐使用 v1.30.14 + Containerd（新特性优先）
3. **开发环境**：建议与生产环境版本保持一致

## 现有脚本分析

### 安装脚本清单及功能

| 脚本文件 | 功能描述 | 参数要求 | 执行顺序 |
|---------|----------|----------|----------|
| `0.ssh_nopasswd.sh` | 配置服务器间免密登录 | 服务器IP列表 | 1 |
| `01.set-env.sh` | 系统环境初始化配置 | 工作目录路径 | 2 |
| `01.dns.sh` | 配置DNS解析 | DNS服务器地址 | 3 |
| `01.yum.sh` | 配置YUM源 | 无 | 4 |
| `01.yum_client.sh` | 配置YUM客户端 | 无 | 5 |
| `02.docker_install.sh` | 安装Docker容器运行时 | 镜像仓库地址 | 6 |
| `02.contaired_install.sh` | 安装Containerd容器运行时 | 无 | 6(备选) |
| `03.registry_install.sh` | 安装私有镜像仓库 | IP地址、架构、用户名、密码、加密标识 | 7 |
| `04.Dependency-Package-yum.sh` | 安装K8s依赖组件 | 无 | 8 |
| `04.Dependency-Package-rpm.sh` | 通过RPM安装依赖 | 无 | 8(备选) |
| `05.init-Cluster.sh` | 初始化K8s集群 | 本机IP、工作路径 | 9 |
| `06.set-admin-conf.sh` | 配置kubectl管理权限 | 无 | 10 |
| `09.nfs_server.sh` | 配置NFS存储服务 | 共享存储路径 | 11 |
| `09.nfs_mount.sh` | 配置NFS客户端挂载 | 共享路径、本机IP、NFS服务器IP | 11 |
| `generate_hosts.sh` | 生成主机环境变量 | 无 | 工具类 |

### 执行流程分析

1. **准备阶段**：SSH免密配置 → 环境变量设置 → DNS配置 → YUM源配置
2. **版本检查**：K8s版本识别 → 运行时版本匹配 → 包版本确定
3. **运行时安装**：
   - **v1.23.17**：优先安装 Docker 20.10.24
   - **v1.30.14**：优先安装 Containerd 1.7.18
4. **镜像仓库**：私有Registry安装配置
5. **K8s组件**：依赖包安装 → 集群初始化 → 管理配置
6. **存储配置**：NFS服务端/客户端配置

## 主控脚本需求

### 1. 脚本串联执行
- **要求**：主控脚本能按顺序执行所有安装脚本
- **逻辑**：简单清晰，避免过度嵌套，便于维护
- **实现**：采用线性执行流程，每个步骤独立函数封装

### 2. 跨服务器执行
- **要求**：支持在控制平面和工作节点同时执行
- **场景**：环境变量配置、运行时安装等需在所有节点执行
- **实现**：基于SSH免密登录，支持批量远程命令执行

### 3. 安装包分发
- **要求**：将安装包和脚本分发到目标服务器
- **实现**：SCP或RSYNC批量传输，支持断点续传

### 4. 配置文件统一管理
- **要求**：提取变量到 `config.yaml` 统一配置
- **内容**：服务器信息、网络配置、存储路径、版本号等
- **格式**：YAML格式，便于阅读和维护

### 5. 工具类支持
- **文件**：`tools.sh` 工具类
- **功能**：提供yq、jq等YAML/JSON处理工具
- **用途**：动态修改配置文件，解析安装状态

### 6. 部署状态记录
- **要求**：记录各阶段部署状态
- **存储**：状态文件或数据库
- **内容**：安装时间、版本信息、执行结果、错误日志
- **作用**：支持断点续传，故障排查

### 7. 验证点机制
- **前置验证**：每阶段开始前检查是否已安装
- **后置验证**：安装完成后验证功能正常性
- **跳过逻辑**：已安装组件自动跳过，支持指定强制重装
- **验证方式**：服务状态检查、版本查询、功能测试

## 配置文件设计 (config.yaml)

```yaml
# 集群基本信息
cluster:
  name: "kubernetes"
  version: "v1.23.17"
  network:
    pod_subnet: "10.42.0.0/16"
    service_subnet: "10.96.0.0/12"
    dns_domain: "cluster.local"

# 服务器配置
servers:
  # 集群架构配置：amd64 或 arm64（所有机器架构必须一致）
  architecture: "amd64"
  master:
    - ip: "192.168.1.10"
      hostname: "k8sc1"
      role: "control-plane"
  workers:
    - ip: "192.168.1.11"
      hostname: "k8sw1"
      role: "worker"
    - ip: "192.168.1.12"
      hostname: "k8sw2"
      role: "worker"

# 系统配置
system:
  dns_servers: ["8.8.8.8", "114.114.114.114"]
  work_dir: "/data/k8s_install"
  disable_swap: true
  disable_firewall: true

# 镜像仓库配置
registry:
  enable: true
  ip: "192.168.1.10"
  port: "5000"
  auth: true
  username: "admin"
  password: "password"
  ui_port: "5080"

# 容器运行时配置 (根据K8s版本自动选择)
container_runtime:
  # Docker配置 (v1.23.17默认)
  docker:
    version: "20.10.24"
    data_root: "/data/docker_root"
    log_max_size: "500m"
    log_max_file: "3"
    insecure_registries: ["registry:5000"]

  # Containerd配置 (v1.30.14默认)
  containerd:
    version: "1.7.18"
    config_path: "/etc/containerd/config.toml"
    data_root: "/data/containerd_root"
    snapshotter: "overlayfs"

# 存储配置
storage:
  nfs:
    enable: true
    server_ip: "192.168.1.10"
    path: "/data/nfs_share"

# K8s组件版本配置
kubernetes:
  # 仅支持两个版本: v1.23.17 或 v1.30.14
  version: "v1.23.17"  # 选择 "v1.23.17" 或 "v1.30.14"

  # 组件版本会根据选择的K8s版本自动匹配
  components:
    # v1.23.17 组件版本
    v1.23.17:
      kubeadm: "1.23.17-0"
      kubelet: "1.23.17-0"
      kubectl: "1.23.17-0"
      cni: "0.8.7-0"
      cri_tools: "1.23.0-0"

    # v1.30.14 组件版本
    v1.30.14:
      kubeadm: "1.30.14-0"
      kubelet: "1.30.14-0"
      kubectl: "1.30.14-0"
      cni: "1.5.1-0"
      cri_tools: "1.30.0-0"

# 部署选项
deployment:
  force_reinstall: false
  skip_existing: true
  backup_before_install: true
  log_level: "INFO"
```

## 主控脚本结构设计

```
kubeeasy-install.sh
├── 全局变量和配置加载
├── 工具函数库 (tools.sh)
├── 验证函数库 (verify.sh)
├── 阶段执行函数
│   ├── prepare_environment()     # 环境准备
│   ├── version_check()          # 版本兼容性检查
│   ├── install_runtime()        # 运行时安装(自动选择Docker/Containerd)
│   ├── setup_registry()         # 镜像仓库
│   ├── install_k8s()           # K8s组件安装
│   ├── init_cluster()          # 集群初始化
│   └── configure_storage()     # 存储配置
├── 状态管理函数
│   ├── save_status()
│   ├── load_status()
│   └── check_status()
└── 主执行流程
    ├── 解析参数
    ├── 加载配置
    ├── 执行部署
    └── 生成报告
```

## 验证点设计

### 系统环境验证
- [ ] Swap已关闭
- [ ] 防火墙已关闭
- [ ] SELinux已配置
- [ ] 内核参数已设置
- [ ] DNS解析正常

### 版本兼容性验证
- [ ] Kubernetes版本仅支持v1.23.17或v1.30.14
- [ ] 容器运行时与K8s版本匹配
  - v1.23.17 ↔ Docker 20.10.24
  - v1.30.14 ↔ Containerd 1.7.18
- [ ] K8s组件版本一致性检查
- [ ] 依赖包版本兼容性验证
- [ ] 集群架构一致性检查（所有节点架构相同）

### 运行时验证
- [ ] Docker/Containerd服务运行状态
- [ ] 版本信息匹配预期版本
- [ ] 配置文件正确性
- [ ] 与K8s版本兼容性检查
- [ ] 网络连通性

### K8s组件验证
- [ ] kubeadm/kubectl/kubelet版本匹配配置
- [ ] 集群初始化状态
- [ ] 节点就绪状态
- [ ] 网络插件状态
- [ ] DNS解析状态
- [ ] 版本兼容性检查

### 功能验证
- [ ] Pod调度功能
- [ ] Service发现
- [ ] 存储挂载
- [ ] 镜像拉取

## 预期输出

1. **安装日志**：详细记录每个步骤的执行过程
2. **状态报告**：集群状态、节点信息、组件版本
3. **配置文件**：生成的各类配置文件备份
4. **错误诊断**：失败时的错误信息和修复建议


## 版本兼容性矩阵

### 支持的组合配置

| K8s 版本 | Docker 版本 | Containerd 版本 | 推荐组合 | 状态 |
|----------|-------------|----------------|----------|------|
| v1.23.17 | 20.10.24 | - | K8s + Docker | ✅ 稳定 |
| v1.30.14 | - | 1.7.18 | K8s + Containerd | ✅ 最新 |

### 版本选择建议

#### 生产环境
- **稳定性优先**：v1.23.17 + Docker 20.10.24

#### 测试环境
- **最新特性**：v1.30.14 + Containerd 1.7.18

#### 开发环境
- **快速部署**：v1.30.14 + Containerd 1.7.18
- **学习环境**：v1.23.17 + Docker 20.10.24

### 架构支持
- **统一架构**：集群中所有服务器必须使用相同的架构
- **支持架构**：amd64 或 arm64
- **配置要求**：在 `servers.architecture` 中指定架构类型

## 后续扩展

1. **集群管理功能**：
   - **状态查询**：集群状态、节点状态、组件状态查询
   - **集群初始化**：快速初始化和重置功能
   - **健康检查**：定期健康检查和报告

2. **高可用支持**：多控制平面配置

3. **运维工具集成**：
   - 日志聚合分析
   - 性能监控告警
   - 备份恢复工具
   - 故障诊断工具