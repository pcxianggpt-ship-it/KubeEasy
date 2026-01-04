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
