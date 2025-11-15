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
- 每个安装模块对应的 `step_*.sh`：每一步的安装逻辑（含“安装器”与“验证器”两部分）。
- `verify_*.sh`：验证脚本，用于判断安装是否完成/生效（可被单独调试）。
- `config.yaml` / `config.json`：所有变量集中管理，支持面向对象式（节点对象）配置。
- `packages/`：预先上传的离线安装包与镜像（包括 rpm、tar、镜像归档）。
- `logs/`：统一日志目录；`status/`：每个步骤的状态文件（JSON/YAML）。

## 5. 安装流程（按顺序）

1. 检查是否为 `root` 用户。
2. 服务器之间免密登录（生成密钥、分发公钥、验证）。
3. 检查并安装依赖（rpm 安装，按 `config` 中的包列表）。
4. 替换 kubeadm 文件（如果需要替换二进制或配置）。
5. 环境变量配置（sysctl、limits、PATH、container runtime 参数等）。
6. 安装 docker/containerd（支持二选一或并行安装策略）。
7. 安装镜像仓库（离线方式：分发镜像 tar 并加载到 registry/harbor）。
8. 初始化集群（kubeadm init，**串行执行**，仅在主控节点上）。
9. 修改 `kube-controller-manager` 的 manifest（例如：添加证书或参数，示例：设置有效期 99 年）。
10. 添加控制平面节点（kubeadm join --control-plane）。
11. 添加工作节点（kubeadm join）。
12. 安装 CNI 插件（例如 flannel）。
13. 安装 nfs-client-provisioner。
14. 安装定制化组件（kubemate、nfs、traefik、prometheus、redis 等，可按 `config` 选择性安装）。
15. 配置定时备份 etcd 的 crontab（离线脚本 + 轮转策略）。

> 说明：其中需要串行执行的关键步骤（如 `init cluster`、`join control-plane`）将由主控脚本保证串行化执行；可以并行化的步骤（如 `环境变量配置`、`依赖安装`、`镜像分发`）将并发推送到多台目标节点执行。

## 6. 并发/串行控制要求

- 主控脚本提供统一的并发控制策略：默认并发度可配置（例如 `CONCURRENCY=10`）。
- 对于每个步骤，在 `step` 元数据中声明 `mode: parallel | serial`，主控脚本按此执行。
- 并行任务需实现幂等与互不干扰（使用 lock、临时目录隔离、回退点等）。
- 串行任务（例如 kubeadm init & join）必须等待前置任务完全成功并确认验证点通过。

## 7. 验证点与幂等性

- 每一步都必须有独立验证器：`verify_<step>.sh`。
  - 验证器先判断当前状态（返回 `OK` / `NOT_OK` / `ERROR`），如果 `OK` 则跳过该步骤。
  - 当验证失败时，主控脚本执行对应的安装脚本 `step_<step>.sh`，安装结束后再次运行验证器以确认。
- 验证点示例：
  - 修改 sysctl：`sysctl net.ipv4.ip_forward` 或 `sysctl net.ipv4.ip_forwarding`（根据内核）来验证。
  - docker：`docker info` 返回正常、并检查 `systemctl is-enabled docker` / `systemctl is-active docker`。
  - kubelet：`systemctl status kubelet` + `kubectl get nodes`（在控制平面可用时）。
- 验证器输出需包含机器、步骤、时间戳、校验项和结果（可写入 `status/${host}_${step}.json`）。

## 8. 配置文件（驱动全流程）

- 支持 YAML/JSON 两种格式（默认 `config.yaml`）。
- 所有变量统一抽出，包含但不限于：
  - 全局变量：`packages_dir`、`registry`、`yum_repo`、`concurrency`、`offline_mode`、`log_dir`、`status_dir`。
  - 节点定义（面向对象式结构）：

```yaml
nodes:
  - id: node-01
    ip: 192.168.65.139
    ssh_user: root
    ssh_pass: Kylin123123    # 可选，建议优先使用密钥
    ipv6: "::1"            # 可选
    roles: [control-plane, etcd]
    arch: amd64
    labels: {zone: az1}
    packages: ["docker-20.10.rpm","containerd-1.6.rpm"]
  - id: node-02
    ip: 192.168.65.141
    ssh_user: root
    ssh_pass: Kylin123123
    roles: [worker]

global:
  packages_dir: "/opt/packages"
  registry: "harbor.local:5000"
  yum_repo: "/opt/localrepo"  # 若无则为空或 null
  concurrency: 8
  verify_timeout: 30
```

- 支持面向对象式扩展：节点是对象（`id` 为唯一标识），包含方法/标签式字段（例如 `pre_tasks`, `post_tasks`, `tolerations` 等），便于扩展与复用。
- 可在 `config` 中声明模块安装顺序、并发模式、以及模块开关（install: true/false）。

## 9. 使用 jq / yq 修改 YAML/JSON

- 脚本中使用 `jq` 修改 JSON，使用 `yq` 修改 YAML（在离线环境下如无二进制则从 `packages/` 分发并安装）。
- 提供封装函数 `tools.sh` 中的 `yaml_set(path, value, file)` / `json_set(path, value, file)`，隐藏工具实现（优先使用内置 `yq`/`jq`，如果缺失则用 sed/awk 作为降级实现）。

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

- `packages/` 目录由用户事先准备并上传到主控节点，主控脚本在 `config` 指定路径下读取。
- 若检测到内网 yum/apt 源存在，脚本可优先使用；否则从 `packages/` 直接 `rpm -Uvh`。
- 镜像导入：`docker load -i image.tar` 或 `ctr images import`（containerd），并在私有 registry 中重新 tag/push（若存在 registry），或在本地静态使用。
- 离线二进制：`kubeadm`、`kubectl`、`kubelet` 二进制和 systemd unit 由 `packages/` 提供，脚本负责分发并安装。

## 14. 兼容性与健壮性

- 在脚本入口进行系统识别并分支处理（例如 RHEL-family 与 Debian-family 的 service 管理差异、python 的可用性、systemd 版本差异）。
- 内置降级方案：如果系统没有 `yq`，脚本尝试用 `sed`/`awk` 修改简单 YAML；如果没有 `sshpass`，提示用户先安装或使用密钥。
- 所有对外部命令的调用都应检查返回码并在失败时写入 `status` 并可重试（可配置重试次数）。

## 15. 安全性考虑

- 密码在 `config` 中为敏感信息时，建议只在短期内存在，支持从外部凭证管理器或环境变量加载（如有条件，建议不在 config 中存明文密码）。
- 对 SSH 密钥分发进行确认，默认不覆盖目标机器已有的 authorized_keys（除非显式 `force_key=true`）。

## 16. 扩展性与模块化

- 每个模块（step）均独立：可单独调试与重复运行。
- `config` 支持启/停模块的开关（例如 `install_flannel: true`）。
- 新的组件只需实现 `step_mycomp.sh` 和 `verify_mycomp.sh` 并在 `config` 中注册即可。

## 17. 输出交付与目录结构（示例）

```
installer/                      # 工程根目录
├─ installer.sh                  # 主控脚本
├─ tools.sh                      # 公共工具库
├─ steps/
│   ├─ step_check_root.sh
│   ├─ step_ssh_key.sh
│   ├─ step_install_deps.sh
│   ├─ step_replace_kubeadm.sh
│   ├─ step_sysctl.sh
│   ├─ step_install_containerd.sh
│   ├─ step_install_registry.sh
│   ├─ step_kubeadm_init.sh
│   ├─ step_join_controlplane.sh
│   ├─ step_join_worker.sh
│   ├─ step_install_cni_flannel.sh
│   ├─ step_install_nfs_client.sh
│   └─ step_install_customs.sh
├─ verify/
│   ├─ verify_sysctl.sh
│   ├─ verify_docker.sh
│   ├─ verify_kubelet.sh
│   └─ verify_cni.sh
├─ config.yaml
├─ packages/
└─ logs/
```

## 18. 示例配置片段（面向对象式节点）

```yaml
nodes:
  - id: mw-control-1
    ip: 192.168.65.139
    ssh_user: root
    ssh_pass: Kylin123123
    ipv6: "::1"
    roles:
      - control-plane
      - etcd
    pre_tasks:
      - check_disk
    post_tasks:
      - report_status
  - id: mw-worker-1
    ip: 192.168.65.142
    ssh_user: root
    roles: [worker]

modules:
  install_docker: true
  install_flannel: true
  install_prometheus: false

global:
  packages_dir: /opt/packages
  concurrency: 6
```

## 19. 测试计划

- 单元测试：对 `tools.sh` 中关键函数（`remote_exec`/`scp_send`/`yaml_set`）编写简单的本地测试脚本。
- 集成测试：在小规模隔离内网环境（3 节点）上验证整套流程，检验并发与串行控制、验证器逻辑。
- 回归测试：反复运行已完成步骤，验证幂等性（已安装步骤应被跳过）。

## 20. 交付物

- 完整脚本集合（`installer.sh`、`tools.sh`、`steps/`、`verify/`）。
- 配置样例 `config.yaml` 和文档说明。
- 离线安装包结构说明（`packages/` 要包含哪些文件）。
- 使用手册：快速开始（上传包、编辑 config、运行主脚本）、排错指南、常见问题。

## 21. 里程碑（建议）

1. 需求评审与 config schema 定稿（1 天）。
2. 实现 `tools.sh`（远程执行、分发、日志、并发控制）（2 天）。
3. 实现基础步骤（check root、ssh-key、install deps、sysctl）（2 天）。
4. 实现容器运行时安装与验证（docker/containerd）（2 天）。
5. 实现 kubeadm init / join（串行可靠）（2 天）。
6. 集成测试与修复（2 天）。

## 22. 其他建议

- 推荐先做一套最小可运行的 PoC（3 节点），把核心流程跑通，再逐步扩展到完整模块。
- 对敏感信息（如 ssh_pass）使用外部密钥管理或在运行时传参，避免长期明文存放。
