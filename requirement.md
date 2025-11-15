# K8s 离线一键部署 —— 需求文档

> 版本：v1.0
>  日期：2025-11-15
>  作者：自动生成（根据用户需求）

## 1. 概述

目标是把现有的一组离线安装 shell 脚本（例如：安装依赖、配置环境变量、安装 docker/containerd、替换 kubeadm 等）改造成一套**可配置、可重入、支持并行/串行流程控制、带规范化日志和状态查询**的全流程自动化安装框架。框架以一个主控 shell 脚本为入口，通过配置文件驱动整个安装流程；在完成免密登录后主节点会把需要的安装介质分发到其他节点，整个过程不依赖外网（不能使用 wget 等命令）。

## 2. 假设与约束

- 离线安装：不能访问外网，不能使用 `wget`、`curl` 从公网拉资源。所有安装包/镜像/rpm/tarball 需先上传到主控节点的指定目录（例如 `packages/`）。
- 多发行版兼容：需支持常见企业发行版（CentOS/RHEL、Kylin、Ubuntu/Centos-like）以及不同环境中缺失的命令（如 python3）。
- 权限假设：在开始执行前，用户会在控制节点以 `root` 身份运行主控脚本（脚本会先检查是否 root）。
- 网络假设：内网可能有/没有 yum/apt 私有源，脚本需检测并采用不同策略。
- 不在每台机器上手工执行：主控脚本在一台节点上运行，自动分发并在目标节点上执行。

## 3. 目标用户

运维工程师 / SRE / 平台工程师，熟悉 shell、ssh、tar、rpm、docker/k8s 基本概念。文档与脚本应便于阅读和二次定制。

## 4. 总体架构与组件

- `installer.sh`（主控脚本）：控制全流程，解析配置、控制并行/串行任务、收集并输出状态。
- `tools.sh`（通用工具集）：通用函数（日志、执行命令封装、远程执行、校验/回退、文件分发、锁机制、并发控制等）。
- 每个安装模块对应的 `step_*.sh`：每一步的安装逻辑（含"安装器"与"验证器"两部分）。
- `verify_*.sh`：验证脚本，用于判断安装是否完成/生效（可被单独调试）。
- `config.yaml` / `config.json`：所有变量集中管理，支持面向对象式（节点对象）配置。
- `packages/`：预先上传的离线安装包与镜像（包括 rpm、tar、镜像归档）路径由global.packages_dir参数控制。
- `installscript/`：基于现有脚本的安装模块集合，包含以下关键组件：
  - `0.ssh_nopasswd.sh`：SSH免密登录配置
  - `01.set-env.sh`：系统环境准备（关闭swap、防火墙、内核参数配置）
  - `01.dns.sh`：DNS配置
  - `01.yum.sh`/`01.yum_client.sh`：YUM源配置（服务器端/客户端）
  - `02.docker_install.sh`：Docker安装与配置（仅 K8s 1.23.17）
  - `02.contaired_install.sh`：containerd安装与配置（仅 K8s 1.30.14）
  - `03.registry_install.sh`：私有镜像仓库安装
  - `04.Dependency-Package-*.sh`：Kubernetes依赖包安装
  - `05.init-Cluster.sh`：Kubernetes集群初始化
  - `06.set-admin-conf.sh`：kubectl配置
  - `09.nfs_*.sh`：NFS服务配置
  - `generate_hosts.sh`：主机名和IP映射生成
- `logs/`：统一日志目录；`status/`：每个步骤的状态文件（JSON/YAML）。

## 5. 安装流程（按顺序）

基于现有脚本的安装流程如下：

1. 检查是否为 `root` 用户。
2. 服务器之间免密登录配置（基于 `0.ssh_nopasswd.sh`）。
3. 系统环境准备（基于 `01.set-env.sh`）：
   - 关闭 swap 分区
   - 停止并禁用防火墙
   - 卸载冲突的容器运行时（podman、containerd）
   - 配置内核模块（overlay、br_netfilter）
   - 配置 sysctl 参数（IPv4/IPv6 转发、桥接等）
4. DNS 配置（基于 `01.dns.sh`）。
5. YUM 源配置：
   - 服务器端配置（基于 `01.yum.sh`）：部署本地 HTTP YUM 源
   - 客户端配置（基于 `01.yum_client.sh`）：配置指向服务器的 YUM 源
6. 容器运行时安装（根据 K8s 版本自动选择）：
   - **K8s 1.23.17**：安装 Docker 20.10.24（基于 `02.docker_install.sh`）
     - Docker 二进制安装与 systemd 服务配置
     - 配置镜像仓库加速和存储目录
   - **K8s 1.30.14**：安装 containerd 1.7.18（基于 `02.contaired_install.sh`）
     - containerd 二进制解压到 `/usr/local/`
     - 安装 runc 二进制到 `/usr/local/sbin/`
     - 配置 containerd 服务和配置文件
     - 配置 crictl 运行时端点
7. 私有镜像仓库部署（基于 `03.registry_install.sh`）：
   - Registry 服务部署（支持用户认证）
   - Registry UI 界面部署
8. Kubernetes 组件安装（基于 `04.Dependency-Package-*.sh`）：
   - 使用 RPM 方式安装 kubeadm、kubectl、kubelet
   - 安装 cri-tools、kubernetes-cni 等依赖
   - 替换 kubeadm 二进制以支持 99 年证书有效期
9. 集群初始化（基于 `05.init-Cluster.sh`）：
   - 生成 kubeadm 配置文件
   - 执行集群初始化
   - 配置 kube-controller-manager 证书有效期
   - 验证控制平面组件状态
10. kubectl 配置（基于 `06.set-admin-conf.sh`）。
11. NFS 存储配置：
    - NFS 服务器配置（基于 `09.nfs_server.sh`）
    - NFS 客户端挂载配置（基于 `09.nfs_mount.sh`）
12. （待扩展）添加控制平面节点和工作节点
13. （待扩展）安装 CNI 插件
14. （待扩展）安装其他定制化组件

> 说明：现有脚本主要覆盖了单节点集群的初始化流程，需要扩展支持多节点集群部署和高可用配置。

> 说明：其中需要串行执行的关键步骤（如 `init cluster`、`join control-plane`）将由主控脚本保证串行化执行；可以并行化的步骤（如 `环境变量配置`、`依赖安装`、`镜像分发`）将并发推送到多台目标节点执行。

## 6. 并发/串行控制要求

基于现有脚本的并发/串行控制策略：

- **串行执行步骤（必须严格按顺序）**：
  - 集群初始化（`05.init-Cluster.sh`）- 必须在主控节点执行
  - 添加控制平面节点（待扩展）- 必须在主节点初始化完成后
  - 添加工作节点（待扩展）- 必须在控制平面就绪后

- **可并行执行步骤**：
  - 系统环境准备（`01.set-env.sh`）- 可在所有节点并行
  - YUM 源客户端配置（`01.yum_client.sh`）- 可在所有工作节点并行
  - 容器运行时安装 - 可在所有节点并行
    - Docker 安装（`02.docker_install.sh`，仅 K8s 1.23.17）
    - containerd 安装（待实现，仅 K8s 1.30.14）
  - Kubernetes 组件安装（`04.Dependency-Package-*.sh`）- 可在所有节点并行
  - NFS 客户端配置（`09.nfs_mount.sh`）- 可在需要挂载的节点并行

- **依赖关系**：
  - SSH 免密登录必须最先完成
  - YUM 源服务器必须在客户端配置前完成
  - 容器运行时（Docker/containerd）必须在私有镜像仓库部署前完成
  - Kubernetes 组件必须在集群初始化前完成

- **主控脚本提供统一的并发控制策略**：默认并发度可配置（例如 `CONCURRENCY=10`）。
- 对于每个步骤，在 `step` 元数据中声明 `mode: parallel | serial`，主控脚本按此执行。
- 并行任务需实现幂等与互不干扰（使用 lock、临时目录隔离、回退点等）。
- 串行任务必须等待前置任务完全成功并确认验证点通过。

## 7. 验证点与幂等性

基于现有脚本的验证策略：

- **现有脚本内置验证机制**：
  - SSH 免密登录：通过 `ssh` 命令测试连通性
  - 系统环境准备：检查 swap、防火墙状态、内核模块加载情况、sysctl 参数值
  - Docker 安装：验证 `systemctl status docker`、`docker info`、socket 文件权限
  - Kubernetes 组件：验证 RPM 包安装状态、服务自启动状态
  - 集群初始化：检查 Pod 运行状态、证书有效期

- **需要实现的独立验证器**：`verify_<step>.sh`。
  - 验证器先判断当前状态（返回 `OK` / `NOT_OK` / `ERROR`），如果 `OK` 则跳过该步骤。
  - 当验证失败时，主控脚本执行对应的安装脚本 `step_<step>.sh`，安装结束后再次运行验证器以确认。

- **验证点示例**：
  - 修改 sysctl：`sysctl net.ipv4.ip_forward` 检查参数值
  - 容器运行时验证：
    - Docker（K8s 1.23.17）：`docker info` 检查运行状态，`systemctl is-enabled docker` 检查自启动
    - containerd（K8s 1.30.14）：`ctr version` 检查版本，`systemctl is-enabled containerd` 检查自启动
  - Kubernetes 组件：`rpm -qa | grep kubelet` 检查包安装，`systemctl status kubelet` 检查服务
  - 集群状态：`kubectl get nodes` 检查节点状态，`kubectl get pods -A` 检查系统 Pod
  - NFS 挂载：`findmnt` 检查挂载状态，`/etc/fstab` 检查自动挂载配置

- **验证器输出需包含**：机器、步骤、时间戳、校验项和结果（可写入 `status/${host}_${step}.json`）。

## 8. 配置文件（驱动全流程）

基于现有脚本参数的配置设计：

- **支持 YAML/JSON 两种格式**（默认 `config.yaml`）。
- **所有变量统一抽出**，包含但不限于：
  - 全局变量：`packages_dir`、`registry`、`yum_repo`、`concurrency`、`offline_mode`、`log_dir`、`status_dir`。
  - **架构配置**：`arch`（amd64 或 arm64），所有节点统一使用相同架构
  - **Kubernetes 版本配置**：`kubernetes_version`（支持 1.23.17 或 1.30.14）
  - **容器运行时选择**：根据 K8s 版本自动选择
    - K8s 1.23.17 → Docker 20.10.24
    - K8s 1.30.14 → containerd 1.7.18
  - 现有脚本参数映射：
    - `01.dns.sh` DNS 服务器地址
    - `01.yum.sh` YUM 源 IP、安装路径、主节点 IP
    - `02.docker_install.sh` 镜像仓库地址（仅 K8s 1.23.17）
    - `02.contaired_install.sh` containerd 安装包路径（仅 K8s 1.30.14）
    - `03.registry_install.sh` 本机 IP、架构、镜像仓库用户名/密码、是否加密
    - `05.init-Cluster.sh` 本机 IP、工作路径
    - `09.nfs_*.sh` NFS 路径、服务器 IP、当前节点 IP

- **节点定义（面向对象式结构）**：

```yaml
nodes:
  - id: k8sc1
    ip: 192.168.62.171
    ssh_user: root
    ssh_pass: Kylin123123    # 可选，建议优先使用密钥
    ipv6: "fd00::171"            # 可选
    roles: [control-plane, etcd]
    labels: {zone: az1}
    pre_tasks:             # 前置任务（可选）
      - check_disk
    post_tasks:            # 后置任务（可选）
      - report_status
  - id: k8sw1
    ip: 192.168.65.174
    ipv6: "fd00::1"            # 可选
    ssh_user: root
    ssh_pass: Kylin123123
    roles: [worker]

# 模块开关（可选）
modules:
  install_flannel: true
  install_prometheus: false

global:
  packages_dir: "/data/k8s_install"
  registry: "registry:5000"
  yum_repo: ""  # 若无则为空或 null
  arch: "amd64"              # amd64 或 arm64，所有节点统一
  concurrency: 8
  verify_timeout: 30
  kubernetes_version: "1.23.17"  # 支持 1.23.17 或 1.30.14

# 容器运行时会根据 kubernetes_version 自动选择：
# - 1.23.17 → Docker 20.10.24
# - 1.30.14 → containerd 1.7.18
```

- 支持面向对象式扩展：节点是对象（`id` 为唯一标识），包含方法/标签式字段（例如 `pre_tasks`, `post_tasks`, `tolerations` 等），便于扩展与复用。
- 可在 `config` 中声明模块安装顺序、并发模式、以及模块开关（install: true/false）。

## 9. 使用 jq / yq 修改 YAML/JSON

- 脚本中使用 `jq` 修改 JSON，使用 `yq` 修改 YAML。
- 工具二进制文件从 `packages/07.tools/` 目录自动分发到所有节点的 `/usr/local/bin/`。
- 提供封装函数 `tools.sh` 中的 `yaml_set(path, value, file)` / `json_set(path, value, file)`，统一工具调用接口。
- 确保所有节点使用相同版本的 yq 和 jq，避免版本差异导致的问题。

## 10. 日志规范化输出

- 统一日志函数：`log(level, step, host, message)`，输出格式：

```
2025-11-15T12:00:00+08:00 [INFO] [node-01] [step:install-docker] Message text
```

- 日志级别： `DEBUG` / `INFO` / `WARN` / `ERROR` / `FATAL`。
- 主控脚本将保留集中日志 `logs/installer_<timestamp>.log`，并且每台目标主机也在 `logs/<host>.log` 写入远程执行日志（主控通过 scp 收集或远程写入到共享路径）。
- 每个步骤结束后生成状态文件（JSON），用于状态查询（见第 11 节）。
- 日志轮转/压缩策略：按日或按大小轮转（可配置）。

## 11. 状态查询与报告

- 在 `status/` 目录保存每台主机每步的状态文件，例如：`status/node-01_install-docker.json`，包含：
  - `host, step, status(OK/NOT_OK/ERROR), start_time, end_time, message, retry_count`。
- 主控脚本提供 `installer.sh status [--host node-01] [--step install-docker]` 子命令，实现快速查询并汇总当前安装进度。
- 提供 `installer.sh logs [--tail N] [--host node-01]` 查看日志。

## 12. 通用工具类（tools.sh）设计要点

- 远程执行：`remote_exec(host, cmd)`（带超时、输出捕获与返回码），支持 ssh 密钥或密码（采用 `sshpass` 可作为降级方案，但优先密钥）。
- 分发文件：`scp_send(host, src, dst)`，支持并发批量分发。
- 并发控制：`parallel_run(func, hosts, concurrency)`。
- 验证封装：`run_verify(host, step)`，封装验证-安装-再验证流程与重试策略。
- 回滚/失败处理：每个 step 定义失败回滚逻辑（可选）。
- 环境兼容检测：`detect_os()`、`ensure_python()`、`ensure_jq_yq()` 等。
- 锁机制：对需要串行的资源（例如对 `kubeadm init`）使用文件锁（`flock`）。

## 13. 离线资源/依赖处理策略

基于现有脚本的离线资源处理：

- **packages/ 目录结构需求**：
  - `06.repo/`：YUM 源相关文件（tar 包形式的本地仓库）
  - `01.rpm_package/`：RPM 包集合
    - `kubelet/`：Kubernetes 组件 RPM 包
    - `kubeadm100y-amd`：支持 99 年证书的 kubeadm 二进制
  - `04.registry/`：镜像仓库相关文件
    - `registry-2.7.1-{arch}.tar`：Registry 镜像
    - `registry-ui-{arch}.tar`：Registry UI 镜像
    - `registry-{arch}.tgz`：Registry 数据目录
  - `docker-20.10.9.tgz`：Docker 二进制包

- **离线资源处理流程**：
  - YUM 源：解压 tar 包到 `/var/www/html/kylinos`，通过 HTTP 服务提供
  - Docker：解压二进制包到 `/usr/bin`，配置 systemd 服务
  - 镜像仓库：`docker load` 导入镜像，配置数据卷挂载
  - Kubernetes 组件：`rpm -ivh` 批量安装 RPM 包

- **依赖检查与降级策略**：
  - 优先使用本地 YUM 源（`01.yum.sh`）
  - 检测并处理冲突软件包（podman、containerd）
  - 确保 conntrack-tools、socat 等依赖可用
  - 支持不同架构（amd64/arm64）的包选择

- **配置文件与参数映射**：
  - 通过主控脚本自动生成各模块所需的参数文件
  - 使用 `generate_hosts.sh` 生成主机名到 IP 的映射变量
  - 动态配置 Registry 地址、NFS 服务器地址等

## 14. 兼容性与健壮性

基于现有脚本的兼容性要求：

- **操作系统支持**：
  - 主要支持：Kylin（麒麟）、CentOS/RHEL 7+ 系统
  - 验证兼容性：现有脚本已在 Kylin 系统上验证
  - 系统检测：支持 RHEL-family 系统的包管理和服务管理

- **架构支持**：
  - AMD64（x86_64）：完全支持
  - ARM64：部分支持（Registry 和 Docker 镜像需要对应架构版本）

- **依赖工具要求**：
  - 必需：`systemd`、`bash`、`rpm`、`yum`
  - 可选：`sshpass`（用于密码认证，建议使用密钥）
  - 网络工具：`curl`、`wget`（仅用于验证，安装过程不需要）

- **健壮性设计**：
  - 每个脚本都有详细的错误检查和状态验证
  - 支持幂等执行（多次运行不会造成重复安装）
  - 自动处理软件包冲突（卸载 podman、containerd）
  - 关键步骤有状态验证，失败时明确提示错误原因

- **工具依赖保障**：
  - yq 和 jq 通过 `07.tools` 目录提供二进制文件，确保所有节点都有一致的工具环境
  - 如果没有 `sshpass`，提示用户使用密钥认证
  - 支持不同版本的 systemd 和内核参数

- **错误处理**：
  - 所有对外部命令的调用都检查返回码
  - 失败时写入 `status` 文件并支持重试（可配置重试次数）
  - 提供清晰的错误信息和排查建议

## 15. 安全性考虑

- 密码在 `config` 中为敏感信息时，建议只在短期内存在，支持从外部凭证管理器或环境变量加载（如有条件，建议不在 config 中存明文密码）。
- 对 SSH 密钥分发进行确认，默认不覆盖目标机器已有的 authorized_keys（除非显式 `force_key=true`）。

## 16. 扩展性与模块化

- 每个模块（step）均独立：可单独调试与重复运行。
- `config` 支持启/停模块的开关（例如 `install_flannel: true`）。
- 新的组件只需实现 `step_mycomp.sh` 和 `verify_mycomp.sh` 并在 `config` 中注册即可。

## 17. 输出交付与目录结构（示例）

基于现有脚本的目录结构设计：

```
installer/                      # 工程根目录
├─ installer.sh                  # 主控脚本
├─ tools.sh                      # 公共工具库
├─ config.yaml                   # 配置文件
├─ installscript/                # 现有脚本集合（已存在）
│   ├─ 0.ssh_nopasswd.sh         # SSH免密登录
│   ├─ 01.set-env.sh             # 系统环境准备
│   ├─ 01.dns.sh                 # DNS配置
│   ├─ 01.yum.sh                 # YUM源服务器
│   ├─ 01.yum_client.sh          # YUM源客户端
│   ├─ 02.docker_install.sh      # Docker安装
│   ├─ 03.registry_install.sh    # 镜像仓库安装
│   ├─ 04.Dependency-Package-yum.sh    # K8s依赖安装（YUM方式）
│   ├─ 04.Dependency-Package-rpm.sh    # K8s依赖安装（RPM方式）
│   ├─ 05.init-Cluster.sh        # 集群初始化
│   ├─ 06.set-admin-conf.sh      # kubectl配置
│   ├─ 09.nfs_server.sh          # NFS服务器
│   ├─ 09.nfs_mount.sh           # NFS客户端
│   └─ generate_hosts.sh         # 主机名映射生成
├─ steps/                        # 新的标准化步骤脚本（待实现）
│   ├─ step01_check_root.sh
│   ├─ step02_ssh_key.sh         # 基于0.ssh_nopasswd.sh
│   ├─ step03_env_prepare.sh     # 基于01.set-env.sh
│   ├─ step04_dns_config.sh      # 基于01.dns.sh
│   ├─ step05_yum_server.sh      # 基于01.yum.sh
│   ├─ step06_yum_client.sh      # 基于01.yum_client.sh
│   ├─ step07_container_runtime.sh  # 基于02.docker_install.sh 或 02.contaired_install.sh
│   ├─ step08_registry_install.sh # 基于03.registry_install.sh
│   ├─ step09_k8s_install.sh     # 基于04.Dependency-Package-*.sh
│   ├─ step10_cluster_init.sh    # 基于05.init-Cluster.sh
│   ├─ step11_admin_conf.sh      # 基于06.set-admin-conf.sh
│   ├─ step12_join_controlplane.sh # 待扩展
│   ├─ step13_join_worker.sh     # 待扩展
│   ├─ step14_cni_install.sh     # 待扩展
│   └─ step15_nfs_config.sh      # 基于09.nfs_*.sh
├─ verify/                       # 验证脚本（待实现）
│   ├─ verify01_root.sh
│   ├─ verify02_ssh.sh
│   ├─ verify03_env.sh
│   ├─ verify04_dns.sh
│   ├─ verify05_yum.sh
│   ├─ verify06_container_runtime.sh  # 验证 Docker 或 containerd
│   ├─ verify07_registry.sh
│   ├─ verify08_k8s_components.sh
│   ├─ verify09_cluster.sh
│   ├─ verify10_admin_conf.sh
│   ├─ verify11_join_controlplane.sh
│   ├─ verify12_join_worker.sh
│   ├─ verify13_cni.sh
│   ├─ verify14_nfs.sh
│   └─ verify15_certificates.sh
├─ logs/                         # 日志目录
└─ status/                       # 状态文件目录
```

基于现有安装包目录结构设计：
路径在global.packages_dir中可配置
```
k8s_install/                      # 安装介质目录（用户上传） 路径配置在global.packages_dir
├── arm/                          # ARM架构安装包
│   ├── 01.rpm_package/            # RPM包
│   │   ├── k8s-1.23.17/
│   │   │   ├── kubeadm-1.23.17-0.arm64.rpm
│   │   │   ├── kubelet-1.23.17-0.arm64.rpm
│   │   │   ├── kubectl-1.23.17-0.arm64.rpm
│   │   │   └── kubernetes-cni-1.2.0-0.arm64.rpm
│   │   ├── k8s-1.30.14/
│   │   │   ├── kubeadm-1.30.14-0.arm64.rpm
│   │   │   ├── kubelet-1.30.14-0.arm64.rpm
│   │   │   ├── kubectl-1.30.14-0.arm64.rpm
│   │   │   └── kubernetes-cni-1.2.0-0.arm64.rpm
│   │   └── system/
│   │       ├── conntrack-tools-1.4.4.arm64.rpm
│   │       ├── socat-1.7.3.arm64.rpm
│   │       ├── iptables-1.8.4.arm64.rpm
│   │       └── ipvsadm-1.31.arm64.rpm
│   ├── 02.container_runtime/      # 容器运行时安装包
│   │   ├── docker/
│   │   │   └── docker-20.10.24.tgz
│   │   └── containerd/
│   │       ├── containerd-1.7.18-linux-arm64.tar.gz
│   │       ├── runc.amd64
│   │       ├── containerd.service
│   │       └── config.toml
│   ├── 03.setup_file/             # 安装配置文件
│   │   ├── k8s-1.23.17/
│   │   │   ├── kubeadm-init.yaml
│   │   │   ├── flannel.yaml
│   │   │   └── nfs-provisioner.yaml
│   │   ├── k8s-1.30.14/
│   │   │   ├── kubeadm-init.yaml
│   │   │   ├── flannel.yaml
│   │   │   └── nfs-provisioner.yaml
│   │   └── custom/
│   │       ├── kubemate.yaml
│   │       ├── traefik.yaml
│   │       ├── prometheus.yaml
│   │       └── redis.yaml
│   ├── 04.registry/               # 镜像仓库安装包
│   │   └── registry/
│   │       └── registry-2.8.2-linux-arm64.tar.gz
│   ├── 05.harbor/                 # Harbor仓库安装包
│   │   └── harbor-offline-installer-v2.8.0-arm64.tgz
│   ├── 06.crontab/                # etcd备份相关包
│   │   ├── etcdctl-v3.5.9-linux-arm64.tar.gz
│   │   └── etcd-backup-script.sh
│   ├── 07.helm/                   # Helm包管理工具
│   │   ├── helm-v3.12.0-linux-arm64.tar.gz
│   │   └── helm-chart-templates/  # Helm chart模板
│   │       ├── nginx/
│   │       │   └── nginx.yaml.template
│   │       └── wordpress/
│   │           └── wordpress.yaml.template
│   └── 07.tools/                  # 工具二进制文件
│       ├── jq-1.6-linux-arm64
│       ├── yq-linux-arm64
│       ├── helm-v3.12.0-linux-arm64.tar.gz
│       ├── kustomize-linux-arm64
│       └── etcdctl-v3.5.9-linux-arm64.tar.gz
├── x86_64/                       # x86_64架构安装包
│   ├── 01.rpm_package/            # RPM包
│   │   ├── k8s-1.23.17/
│   │   │   ├── kubeadm-1.23.17-0.x86_64.rpm
│   │   │   ├── kubelet-1.23.17-0.x86_64.rpm
│   │   │   ├── kubectl-1.23.17-0.x86_64.rpm
│   │   │   └── kubernetes-cni-1.2.0-0.x86_64.rpm
│   │   ├── k8s-1.30.14/
│   │   │   ├── kubeadm-1.30.14-0.x86_64.rpm
│   │   │   ├── kubelet-1.30.14-0.x86_64.rpm
│   │   │   ├── kubectl-1.30.14-0.x86_64.rpm
│   │   │   └── kubernetes-cni-1.2.0-0.x86_64.rpm
│   │   └── system/
│   │       ├── conntrack-tools-1.4.4.x86_64.rpm
│   │       ├── socat-1.7.3.x86_64.rpm
│   │       ├── iptables-1.8.4.x86_64.rpm
│   │       └── ipvsadm-1.31.x86_64.rpm
│   ├── 02.container_runtime/      # 容器运行时安装包
│   │   ├── docker/
│   │   │   └── docker-20.10.24.tgz
│   │   └── containerd/
│   │       ├── containerd-1.7.18-linux-amd64.tar.gz
│   │       ├── runc.amd64
│   │       ├── containerd.service
│   │       └── config.toml
│   ├── 03.setup_file/             # 安装配置文件
│   │   ├── k8s-1.23.17/
│   │   │   ├── kubeadm-init.yaml
│   │   │   ├── flannel.yaml
│   │   │   └── nfs-provisioner.yaml
│   │   ├── k8s-1.30.14/
│   │   │   ├── kubeadm-init.yaml
│   │   │   ├── flannel.yaml
│   │   │   └── nfs-provisioner.yaml
│   │   └── custom/
│   │       ├── kubemate.yaml
│   │       ├── traefik.yaml
│   │       ├── prometheus.yaml
│   │       └── redis.yaml
│   ├── 04.registry/               # 镜像仓库安装包
│   │   └── registry/
│   │       └── registry-2.8.2-linux-amd64.tar.gz
│   ├── 05.harbor/                 # Harbor仓库安装包
│   │   └── harbor-offline-installer-v2.8.0-amd64.tgz
│   ├── 06.crontab/                # etcd备份相关包
│   │   ├── etcdctl-v3.5.9-linux-amd64.tar.gz
│   │   └── etcd-backup-script.sh
│   ├── 07.helm/                   # Helm包管理工具
│   │   ├── helm-v3.12.0-linux-amd64.tar.gz
│   │   └── helm-chart-templates/  # Helm chart模板
│   │       ├── nginx/
│   │       │   └── nginx.yaml.template
│   │       └── wordpress/
│   │           └── wordpress.yaml.template
│   └── 07.tools/                  # 工具二进制文件
│       ├── jq-1.6-linux-amd64
│       ├── yq-linux-amd64
│       ├── helm-v3.12.0-linux-amd64.tar.gz
│       ├── kustomize-linux-amd64
│       └── etcdctl-v3.5.9-linux-amd64.tar.gz
```
## 18. 测试计划

- 单元测试：对 `tools.sh` 中关键函数（`remote_exec`/`scp_send`/`yaml_set`）编写简单的本地测试脚本。
- 集成测试：在小规模隔离内网环境（3 节点）上验证整套流程，检验并发与串行控制、验证器逻辑。
- 回归测试：反复运行已完成步骤，验证幂等性（已安装步骤应被跳过）。

## 20. 交付物

基于现有脚本的交付清单：

- **核心框架**：
  - `installer.sh`：主控脚本（待实现）
  - `tools.sh`：公共工具库（待实现）
  - `config.yaml`：配置样例文件（待完善）

- **现有脚本集成**：
  - 保留 `installscript/` 目录下的所有现有脚本
  - 将现有脚本作为新框架的底层实现，保持向后兼容
  - 逐步迁移现有脚本到标准化的 `steps/` 和 `verify/` 目录

- **标准化步骤脚本**：
  - `steps/`：基于现有脚本重构的标准化步骤脚本
  - `verify/`：独立的验证脚本
  - 确保每个步骤都有对应的验证器

- **离线安装包结构说明**：
  - `packages/` 目录的详细文件清单和结构说明
  - 各架构（amd64/arm64）所需的包列表
  - 镜像仓库中的镜像清单和版本信息

- **文档**：
  - 使用手册：快速开始（上传包、编辑 config、运行主脚本）
  - 现有脚本的使用指南和参数说明
  - 排错指南：基于现有脚本的常见问题解决方法
  - API 文档：tools.sh 中的工具函数说明

- **测试和验证**：
  - 单节点集群部署验证流程
  - 多节点集群扩展测试用例
  - 故障恢复和回滚测试

## 21. 里程碑（建议）

基于现有脚本的分阶段实施计划：

**阶段一：基础框架实现（3-4天）**
1. **需求评审与 config schema 定稿**（0.5 天）
   - 完成配置文件结构设计
   - 定义现有脚本的参数映射规则

2. **实现 `tools.sh` 核心工具**（1.5 天）
   - 远程执行函数（基于现有 SSH 机制）
   - 日志和状态管理函数
   - 并发控制和锁机制
   - 配置文件解析（支持 YAML）

3. **实现 `installer.sh` 主控脚本**（1 天）
   - 配置文件解析和验证
   - 步骤执行控制逻辑
   - 状态查询和日志管理
   - 命令行接口设计

4. **迁移现有脚本到新框架**（1 天）
   - 创建 wrapper 脚本调用现有的 `installscript/` 中的脚本
   - 实现基础验证器
   - 测试单节点部署流程

**阶段二：标准化和扩展（4-5天）**
5. **重构现有脚本为标准化步骤**（2 天）
   - 将现有脚本重构为 `step_*.sh` 和 `verify_*.sh`
   - 实现完整的验证逻辑
   - 统一错误处理和重试机制

6. **实现多节点支持**（2 天）
   - 节点加入逻辑（kubeadm join）
   - CNI 插件安装
   - 集群状态验证

7. **集成测试与修复**（1 天）
   - 多节点集群部署测试
   - 并发执行验证
   - 故障恢复测试

**阶段三：优化和文档（2-3天）**
8. **性能优化和错误处理**（1 天）
   - 优化并发执行效率
   - 完善错误处理和回滚机制
   - 增强日志和状态报告

9. **文档编写和用户指南**（1-2 天）
   - 完整的使用手册
   - 配置说明和示例
   - 排错指南和 FAQ

**总计：9-12天**

## 22. 其他建议

基于现有脚本实施的建议：

- **渐进式改进策略**：
  - 保留现有 `installscript/` 脚本作为底层实现，确保当前功能不受影响
  - 新框架作为上层控制逻辑，逐步替换和优化现有脚本
  - 优先实现单节点集群的自动化部署，验证框架可行性

- **最小可行产品（MVP）**：
  - 基于 `05.init-Cluster.sh` 实现单节点 K8s 集群自动部署
  - 集成 `01.set-env.sh`、`02.docker_install.sh`、`04.Dependency-Package-*.sh`
  - 实现基础的配置文件驱动和状态管理

- **现有脚本的优势和限制**：
  - **优势**：已在 Kylin 系统上验证，支持 99 年证书，包含完整的离线部署逻辑
  - **限制**：主要是单节点部署，缺乏多节点支持，错误处理可以进一步标准化
  - **改进点**：参数化配置、并发执行、状态持久化

- **安全性建议**：
  - 对敏感信息（如 ssh_pass、registry 密码）使用环境变量或外部密钥管理
  - 在生产环境中建议使用 SSH 密钥而非密码认证
  - 定期轮换镜像仓库的访问凭证

- **测试策略**：
  - 先在虚拟机环境中验证完整流程
  - 测试不同网络条件下的部署（内网、隔离网络）
  - 验证离线包的完整性和版本兼容性

- **维护和扩展**：
  - 建立版本化的离线包管理机制
  - 支持 Kubernetes 版本升级路径
  - 考虑添加容器运行时选择（Docker vs containerd）
