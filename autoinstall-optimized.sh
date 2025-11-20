#!/bin/bash

#=============================================================================
# KubeEasy Kubernetes 集群自动安装脚本 (优化版本)
#
# 功能特性:
# - 模块化函数设计
# - 并发执行支持
# - 统一错误处理
# - 详细状态跟踪
# - 灵活配置管理
#=============================================================================

# 全局配置
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/logs/install.log"
readonly STATUS_DIR="${SCRIPT_DIR}/status"

# 创建必要目录
mkdir -p "$(dirname "$LOG_FILE")" "$STATUS_DIR"

#=============================================================================
# 配置文件管理
#=============================================================================

# 加载配置文件
load_config() {
    local config_file="${1:-config.yaml}"

    if [ ! -f "$config_file" ]; then
        echo "错误: 配置文件 $config_file 不存在"
        exit 1
    fi

    echo "加载配置文件: $config_file"

    # 使用yq加载配置变量，如果没有yq则使用默认值
    if command -v yq >/dev/null 2>&1; then
        # 加载基本路径配置
        export data_path=$(yq eval '.system.data_path // "/data/k8s_install"' "$config_file" | tr -d '"')
        export work_dir=$(yq eval '.system.work_dir // "/data"' "$config_file" | tr -d '"')

        # 加载镜像仓库配置
        export registry_ip=$(yq eval '.registry.ip' "$config_file" | tr -d '"')
        export registry_port=$(yq eval '.registry.port' "$config_file" | tr -d '"')
        export registry_user=$(yq eval '.registry.username' "$config_file" | tr -d '"')
        export registry_passwd=$(yq eval '.registry.password' "$config_file" | tr -d '"')

        # 加载其他系统配置
        export dns_ip=$(yq eval '.system.dns_servers[0] // "192.168.62.1"' "$config_file" | tr -d '"')

        log_info "配置加载完成:"
        log_info "  data_path: $data_path"
        log_info "  registry_ip: $registry_ip:$registry_port"
        log_info "  dns_ip: $dns_ip"
    else
        log_error "yq工具未安装，无法解析config.yaml，请先安装yq"
        exit 1
    fi
}

#=============================================================================
# 日志和状态管理函数
#=============================================================================

# 统一日志记录函数
log_info() {
    local message="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [INFO] $message" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [ERROR] $message" | tee -a "$LOG_FILE"
}

log_success() {
    local message="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [SUCCESS] $message" | tee -a "$LOG_FILE"
}

# 阶段状态检查和记录
exit_status_check() {
    local operation="$1"
    local exit_code=${2:-$?}

    if [ $exit_code -eq 0 ]; then
        log_success "$operation 操作成功"
        return 0
    else
        log_error "$operation 操作失败 (退出码: $exit_code)"
        return 1
    fi
}

# 保存阶段状态
save_stage_status() {
    local stage="$1"
    local status="$2"  # success, failed, in_progress
    local message="$3"

    local status_file="$STATUS_DIR/${stage}.status"
    echo "stage=$stage" > "$status_file"
    echo "status=$status" >> "$status_file"
    echo "timestamp=$(date +'%Y-%m-%d %H:%M:%S')" >> "$status_file"
    echo "message=$message" >> "$status_file"

    log_info "阶段状态: $stage = $status"
}

# 检查阶段是否完成
is_stage_completed() {
    local stage="$1"
    local status_file="$STATUS_DIR/${stage}.status"

    if [ -f "$status_file" ]; then
        local status=$(grep "^status=" "$status_file" | cut -d'=' -f2)
        [ "$status" = "success" ]
    else
        return 1
    fi
}

#=============================================================================
# SSH 执行函数 (优化高频使用的方法)
#=============================================================================

# 基础SSH执行函数
ssh_execute() {
    local server="$1"
    local command="$2"
    local show_output=${3:-false}

    log_debug "在 $server 执行: $command"

    if [ "$show_output" = "true" ]; then
        ssh root@"$server" "$command" 2>&1
    else
        ssh root@"$server" "$command" >/dev/null 2>&1
    fi
}

# SSH执行并检查结果
ssh_execute_check() {
    local server="$1"
    local command="$2"
    local description="$3"

    if ssh_execute "$server" "$command"; then
        log_success "$description 在 $server 执行成功"
        return 0
    else
        log_error "$description 在 $server 执行失败"
        return 1
    fi
}

# 批量SSH执行函数 (支持并发)
ssh_execute_batch() {
    local servers=("$@")
    local command="$1"
    local description="$2"
    local use_parallel=${3:-false}

    if [ "$use_parallel" = "true" ]; then
        ssh_execute_parallel "${servers[@]}" "$command" "$description"
    else
        ssh_execute_sequential "${servers[@]}" "$command" "$description"
    fi
}

# 串行执行SSH命令
ssh_execute_sequential() {
    local servers=("$@")
    local command="$1"
    local description="$2"
    shift 2
    servers=("$@")

    local failed_count=0

    log_info "串行执行: $description (${#servers[@]} 个节点)"

    for server in "${servers[@]}"; do
        if ! ssh_execute_check "$server" "$command" "$description"; then
            failed_count=$((failed_count + 1))
        fi
    done

    if [ $failed_count -eq 0 ]; then
        log_success "$description 串行执行全部成功"
        return 0
    else
        log_error "$description 串行执行失败: $failed_count/${#servers[@]}"
        return 1
    fi
}

# 并发执行SSH命令
ssh_execute_parallel() {
    local servers=("$@")
    local command="$1"
    local description="$2"
    shift 2
    servers=("$@")

    local pids=()
    local temp_files=()

    log_info "并发执行: $description (${#servers[@]} 个节点)"

    # 启动并发进程
    for server in "${servers[@]}"; do
        local temp_file="$STATUS_DIR/parallel_${server}_$$.tmp"
        temp_files+=("$temp_file")

        (
            if ssh_execute "$server" "$command"; then
                echo "server=$server,result=0" > "$temp_file"
            else
                echo "server=$server,result=1" > "$temp_file"
            fi
        ) &
        pids+=($!)
    done

    # 等待所有进程完成
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # 分析结果
    local success_count=0
    local failed_count=0

    for temp_file in "${temp_files[@]}"; do
        if [ -f "$temp_file" ]; then
            local server=$(grep "server=" "$temp_file" | cut -d'=' -f2)
            local result=$(grep "result=" "$temp_file" | cut -d'=' -f2)

            if [ "$result" -eq 0 ]; then
                log_success "$description 在 $server 执行成功"
                success_count=$((success_count + 1))
            else
                log_error "$description 在 $server 执行失败"
                failed_count=$((failed_count + 1))
            fi

            rm -f "$temp_file"
        fi
    done

    if [ $failed_count -eq 0 ]; then
        log_success "$description 并发执行全部成功 ($success_count/${#servers[@]})"
        return 0
    else
        log_error "$description 并发执行失败: $failed_count/${#servers[@]}"
        return 1
    fi
}

# 执行远程脚本函数
ssh_execute_script() {
    local server="$1"
    local script_path="$2"
    local args="$3"
    local description="${4:-执行脚本}"

    if [ ! -f "$script_path" ]; then
        log_error "脚本文件不存在: $script_path"
        return 1
    fi

    local command="bash -s"
    if [ -n "$args" ]; then
        command="bash -s $args"
    fi

    ssh root@"$server" "$command" < "$script_path"
}

# 批量执行远程脚本 (高频使用模式)
ssh_execute_script_batch() {
    local servers=("$@")
    local script_path="$1"
    local args="$2"
    local description="${3:-执行脚本}"
    local use_parallel=${4:-false}
    shift 4
    servers=("$@")

    if [ "$use_parallel" = "true" ]; then
        local pids=()

        log_info "并发执行脚本: $description (${#servers[@]} 个节点)"

        for server in "${servers[@]}"; do
            (
                if ssh_execute_script "$server" "$script_path" "$args" "$description"; then
                    log_success "$description 在 $server 执行成功"
                else
                    log_error "$description 在 $server 执行失败"
                fi
            ) &
            pids+=($!)
        done

        # 等待所有进程完成
        for pid in "${pids[@]}"; do
            wait "$pid"
        done

        log_info "脚本并发执行完成: $description"
    else
        log_info "串行执行脚本: $description (${#servers[@]} 个节点)"

        for server in "${servers[@]}"; do
            if ssh_execute_script "$server" "$script_path" "$args" "$description"; then
                log_success "$description 在 $server 执行成功"
            else
                log_error "$description 在 $server 执行失败"
                return 1
            fi
        done

        log_success "脚本串行执行完成: $description"
    fi
}

# 文件分发函数
distribute_file() {
    local local_file="$1"
    local remote_path="$2"
    local servers=("${@:3}")

    if [ ! -f "$local_file" ]; then
        log_error "本地文件不存在: $local_file"
        return 1
    fi

    log_info "分发文件 $local_file 到 ${#servers[@]} 个节点"

    for server in "${servers[@]}"; do
        if scp "$local_file" "root@$server:$remote_path"; then
            log_success "文件分发成功: $local_file -> $server:$remote_path"
        else
            log_error "文件分发失败: $local_file -> $server:$remote_path"
            return 1
        fi
    done

    return 0
}

#=============================================================================
# 条件检查函数 (高频使用模式)
#=============================================================================

# 检查远程命令执行结果
check_remote_command() {
    local server="$1"
    local command="$2"
    local expected_pattern="$3"

    local result=$(ssh_execute "$server" "$command" true)

    if echo "$result" | grep -q "$expected_pattern"; then
        return 0
    else
        return 1
    fi
}

# 检查服务状态
check_service_status() {
    local server="$1"
    local service="$2"
    local expected_state="${3:-active}"

    ssh_execute "$server" "systemctl is-active $service" true | grep -q "$expected_state"
}

# 检查端口是否监听
check_port_listening() {
    local server="$1"
    local port="$2"

    ssh_execute "$server" "netstat -tlnp | grep :$port" true
}

# 检查文件是否存在
check_file_exists() {
    local server="$1"
    local file_path="$2"

    ssh_execute "$server" "test -f $file_path"
}

# 检查包是否已安装
check_package_installed() {
    local server="$1"
    local package="$2"

    ssh_execute "$server" "rpm -q $package" >/dev/null 2>&1
}

#=============================================================================
# 集群操作函数
#=============================================================================

# 节点操作函数
execute_on_nodes() {
    local operation="$1"
    local node_type="$2"  # master, worker, all
    local function_name="$3"
    shift 3
    local args=("$@")

    local nodes=()

    case "$node_type" in
        "master") nodes=("${master_ips[@]}") ;;
        "worker") nodes=("${worker_ips[@]}") ;;
        "all") nodes=("${k8s_nodes[@]}") ;;
        "registry") nodes=("${registry_ip[@]}") ;;
        *)
            log_error "不支持的节点类型: $node_type"
            return 1
            ;;
    esac

    log_info "在 $node_type 节点上执行: $operation (${#nodes[@]} 个节点)"

    if [ "$node_type" = "master" ]; then
        for ip in "${nodes[@]}"; do
            if ! "$function_name" "$ip" "${args[@]}"; then
                log_error "$operation 失败: $ip"
                return 1
            fi
        done
    else
        for ip in "${nodes[@]}"; do
            if ! "$function_name" "$ip" "${args[@]}"; then
                log_error "$operation 失败: $ip"
                return 1
            fi
        done
    fi

    log_success "$operation 在所有 $node_type 节点执行成功"
}

#=============================================================================
# 环境检查和工具安装函数
#=============================================================================

# 检查并安装yq工具
install_yq() {
    if command -v yq >/dev/null 2>&1; then
        log_info "yq工具已安装"
        return 0
    fi

    log_info "开始安装yq工具..."

    # 获取系统架构
    local arch=$(uname -m)
    local yq_arch=""

    case "$arch" in
        "x86_64")
            yq_arch="amd64"
            ;;
        "aarch64"|"arm64")
            yq_arch="arm64"
            ;;
        *)
            log_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac

    # 优先从本地工具目录安装
    if [ -f "tools/yq_linux_${yq_arch}" ]; then
        log_info "从本地工具目录安装yq"
        cp "tools/yq_linux_${yq_arch}" /usr/local/bin/yq
        chmod +x /usr/local/bin/yq

        # 验证安装
        if command -v yq >/dev/null 2>&1; then
            local yq_version=$(yq --version 2>/dev/null | cut -d' ' -f4)
            log_success "yq工具安装成功 (版本: $yq_version)"
            return 0
        else
            log_error "yq工具安装失败"
            return 1
        fi
    else
        log_error "找不到本地yq工具文件: tools/yq_linux_${yq_arch}"
        log_error "请确保yq工具文件存在或手动安装yq"
        return 1
    fi
}

# 检查系统环境
check_system_environment() {
    log_info "开始检查系统环境..."

    local missing_tools=()

    # 检查必需的命令
    local required_commands=("bash" "ssh" "scp"  "tar")

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_tools+=("$cmd")
        fi
    done

    # 检查操作系统类型
    local os_info=""
    if [ -f /etc/os-release ]; then
        os_info=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
        log_info "操作系统: $os_info"
    else
        log_info "无法检测操作系统信息"
    fi

    # 检查系统架构
    local arch=$(uname -m)
    log_info "系统架构: $arch"

    # 检查root权限
    if [ "$EUID" -ne 0 ]; then
        log_error "此脚本需要root权限运行"
        return 1
    else
        log_info "权限检查: 具有root权限"
    fi

    # 检查是否存在缺失工具
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "缺少必需的工具: ${missing_tools[*]}"
        log_error "请先安装这些工具后再运行脚本"
        return 1
    fi

    # 检查并安装yq
    if ! install_yq; then
        log_error "yq工具安装失败"
        return 1
    fi

    # 检查网络连接
    log_info "检查网络连接..."
    if ping -c 1 github.com >/dev/null 2>&1; then
        log_info "网络连接正常"
    else
        log_error "网络连接异常，无法访问github.com"
        return 1
    fi

    log_success "系统环境检查通过"
    return 0
}

#=============================================================================
# 具体安装函数 (基于原有逻辑的函数化版本)
#=============================================================================

# 读取YAML配置函数
read_yaml_value() {
    local config_file="$1"
    local key_path="$2"
    local default_value="$3"

    # 使用yq工具读取配置，如果没有安装则使用简单的grep方式
    if command -v yq >/dev/null 2>&1; then
        local value=$(yq eval "$key_path // \"$default_value\"" "$config_file" 2>/dev/null)
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            echo "$default_value"
        else
            echo "$value"
        fi
    else
        # 简单的YAML解析（仅支持基本结构）
        local value=$(grep -A 5 "^$key_path:" "$config_file" | grep -v "^--" | head -1 | sed 's/^[^:]*: *//' | tr -d '"')
        if [ -z "$value" ]; then
            echo "$default_value"
        else
            echo "$value"
        fi
    fi
}

# 解析服务器列表
parse_server_list() {
    local config_file="$1"
    local server_type="$2"  # master, workers, registry

    local ips=()
    local hostnames=()

    case "$server_type" in
        "master")
            local master_count=$(read_yaml_value "$config_file" '.servers.master | length' "0")
            for ((i=0; i<master_count; i++)); do
                local ip=$(read_yaml_value "$config_file" ".servers.master[$i].ip" "")
                local hostname=$(read_yaml_value "$config_file" ".servers.master[$i].hostname" "")
                if [ -n "$ip" ]; then
                    ips+=("$ip")
                    if [ -n "$hostname" ]; then
                        hostnames+=("$hostname")
                    fi
                fi
            done
            ;;
        "workers")
            local worker_count=$(read_yaml_value "$config_file" '.servers.workers | length' "0")
            for ((i=0; i<worker_count; i++)); do
                local ip=$(read_yaml_value "$config_file" ".servers.workers[$i].ip" "")
                local hostname=$(read_yaml_value "$config_file" ".servers.workers[$i].hostname" "")
                if [ -n "$ip" ]; then
                    ips+=("$ip")
                    if [ -n "$hostname" ]; then
                        hostnames+=("$hostname")
                    fi
                fi
            done
            ;;
        "registry")
            local registry_count=$(read_yaml_value "$config_file" '.servers.registry | length' "0")
            for ((i=0; i<registry_count; i++)); do
                local ip=$(read_yaml_value "$config_file" ".servers.registry[$i].ip" "")
                local hostname=$(read_yaml_value "$config_file" ".servers.registry[$i].hostname" "")
                if [ -n "$ip" ]; then
                    ips+=("$ip")
                    if [ -n "$hostname" ]; then
                        hostnames+=("$hostname")
                    fi
                fi
            done
            ;;
    esac

    # 返回IP和主机名数组
    echo "${ips[@]}|${hostnames[@]}"
}

# 生成hosts文件内容
generate_hosts_content() {
    local config_file="$1"
    local all_ips=()
    local all_hostnames=()

    # 解析各类服务器
    local master_result=$(parse_server_list "$config_file" "master")
    local master_ips=($(echo "$master_result" | cut -d'|' -f1))
    local master_hostnames=($(echo "$master_result" | cut -d'|' -f2))

    local worker_result=$(parse_server_list "$config_file" "workers")
    local worker_ips=($(echo "$worker_result" | cut -d'|' -f1))
    local worker_hostnames=($(echo "$worker_result" | cut -d'|' -f2))

    local registry_result=$(parse_server_list "$config_file" "registry")
    local registry_ips=($(echo "$registry_result" | cut -d'|' -f1))
    local registry_hostnames=($(echo "$registry_result" | cut -d'|' -f2))

    # 生成hosts文件内容
    local hosts_content="127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
"

    # 添加所有服务器到hosts
    for ((i=0; i<${#master_ips[@]}; i++)); do
        if [ $i -lt ${#master_hostnames[@]} ] && [ -n "${master_hostnames[$i]}" ]; then
            hosts_content+="${master_ips[$i]}   ${master_hostnames[$i]}
"
        else
            hosts_content+="${master_ips[$i]}   k8sc$((i+1))
"
        fi
    done

    for ((i=0; i<${#worker_ips[@]}; i++)); do
        if [ $i -lt ${#worker_hostnames[@]} ] && [ -n "${worker_hostnames[$i]}" ]; then
            hosts_content+="${worker_ips[$i]}   ${worker_hostnames[$i]}
"
        else
            hosts_content+="${worker_ips[$i]}   k8sw$((i+1))
"
        fi
    done

    for ((i=0; i<${#registry_ips[@]}; i++)); do
        if [ $i -lt ${#registry_hostnames[@]} ] && [ -n "${registry_hostnames[$i]}" ]; then
            hosts_content+="${registry_ips[$i]}   ${registry_hostnames[$i]}
"
        else
            hosts_content+="${registry_ips[$i]}   registry
"
        fi
    done

    echo "$hosts_content"
}

# 初始化节点变量
initialize_node_variables() {
    local config_file="${CONFIG_FILE:-config.yaml}"

    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq工具未安装，无法初始化节点变量"
        return 1
    fi

    log_info "初始化节点变量..."

    # 初始化数组变量
    master_ips=()
    worker_ips=()
    registry_ips=()
    k8s_nodes=()
    all_nodes=()

    # 读取控制节点IP
    local master_count=$(yq eval '.servers.master | length' "$config_file")
    for ((i=0; i<master_count; i++)); do
        master_ips+=($(yq eval ".servers.master[$i].ip" "$config_file"))
        k8s_nodes+=($(yq eval ".servers.master[$i].ip" "$config_file"))
        all_nodes+=($(yq eval ".servers.master[$i].ip" "$config_file"))
    done

    # 读取工作节点IP
    local worker_count=$(yq eval '.servers.workers | length' "$config_file")
    for ((i=0; i<worker_count; i++)); do
        worker_ips+=($(yq eval ".servers.workers[$i].ip" "$config_file"))
        k8s_nodes+=($(yq eval ".servers.workers[$i].ip" "$config_file"))
        all_nodes+=($(yq eval ".servers.workers[$i].ip" "$config_file"))
    done

    # 读取镜像仓库节点IP
    local registry_count=$(yq eval '.servers.registry | length' "$config_file")
    for ((i=0; i<registry_count; i++)); do
        registry_ips+=($(yq eval ".servers.registry[$i].ip" "$config_file"))
        all_nodes+=($(yq eval ".servers.registry[$i].ip" "$config_file"))
    done

    # 导出数组变量供其他函数使用
    export master_ips worker_ips registry_ips k8s_nodes all_nodes

    log_info "节点变量初始化完成:"
    log_info "  控制节点: ${#master_ips[@]} 个"
    log_info "  工作节点: ${#worker_ips[@]} 个"
    log_info "  镜像仓库节点: ${#registry_ips[@]} 个"
    log_info "  总节点数: ${#all_nodes[@]} 个"
}

# 安装sshpass工具
install_sshpass() {
    if command -v sshpass >/dev/null 2>&1; then
        log_info "sshpass工具已安装"
        return 0
    fi

    log_info "开始安装sshpass工具..."

    # 检查包管理器并安装sshpass
    if command -v yum >/dev/null 2>&1; then
        # CentOS/RHEL系统
        yum install -y sshpass >/dev/null 2>&1
    elif command -v apt >/dev/null 2>&1; then
        # Ubuntu/Debian系统
        apt-get update >/dev/null 2>&1
        apt-get install -y sshpass >/dev/null 2>&1
    else
        log_error "无法安装sshpass，请手动安装"
        return 1
    fi

    if command -v sshpass >/dev/null 2>&1; then
        log_success "sshpass工具安装成功"
        return 0
    else
        log_error "sshpass工具安装失败"
        return 1
    fi
}

# 使用sshpass自动分发SSH公钥
distribute_ssh_key_with_password() {
    local server_ip="$1"
    local password="$2"
    local ssh_key_path="$3"

    log_info "使用密码自动分发SSH公钥到: $server_ip"

    # 创建临时expect脚本
    local expect_script="/tmp/ssh_key_expect_$$"
    cat > "$expect_script" << EOF
#!/usr/bin/expect -f

spawn ssh-copy-id -i "$ssh_key_path" root@$server_ip
expect {
    "yes/no" { send "yes\r"; exp_continue }
    "password:" { send "$password\r"; exp_continue }
    eof
}
EOF

    # 执行expect脚本
    expect "$expect_script" >/dev/null 2>&1
    local result=$?
    rm -f "$expect_script"

    return $result
}

# 使用sshpass手动复制公钥
manual_distribute_ssh_key() {
    local server_ip="$1"
    local password="$2"
    local ssh_key_content="$3"

    log_info "手动复制SSH公钥到: $server_ip"

    # 使用sshpass创建.ssh目录和复制公钥
    sshpass -p "$password" ssh -o StrictHostKeyChecking=no root@"$server_ip" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh" >/dev/null 2>&1 || return 1

    sshpass -p "$password" ssh -o StrictHostKeyChecking=no root@"$server_ip" \
        "echo '$ssh_key_content' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" >/dev/null 2>&1 || return 1

    return 0
}

# 配置SSH免密登录
setup_ssh_keyless() {
    if is_stage_completed "ssh_keyless"; then
        log_info "SSH免密登录配置已完成，跳过"
        return 0
    fi

    log_info "开始配置SSH免密登录"
    save_stage_status "ssh_keyless" "in_progress" "配置SSH免密登录"

    # 从配置文件读取节点密码
    local config_file="${CONFIG_FILE:-config.yaml}"
    local node_password=$(yq eval '.system.node_password // ""' "$config_file" | tr -d '"')

    if [ -z "$node_password" ]; then
        log_info "未在配置文件中找到节点密码，尝试手动交互方式"
        node_password=""
    else
        log_info "从配置文件读取到节点密码"
    fi

    # 安装sshpass工具
    if ! install_sshpass; then
        log_error "sshpass工具安装失败，无法进行自动密码认证"
        save_stage_status "ssh_keyless" "failed" "sshpass工具安装失败"
        return 1
    fi

    # 检查SSH密钥是否存在，如果不存在则生成
    if [ ! -f ~/.ssh/id_rsa ]; then
        log_info "生成SSH密钥对"
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_success "SSH密钥对生成成功"
        else
            log_error "SSH密钥对生成失败"
            save_stage_status "ssh_keyless" "failed" "SSH密钥对生成失败"
            return 1
        fi
    else
        log_info "SSH密钥对已存在"
    fi

    # 获取SSH公钥内容
    local ssh_key_content=$(cat ~/.ssh/id_rsa.pub)

    # 配置本地SSH配置
    cat > ~/.ssh/config << 'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
    LogLevel=ERROR
EOF
    chmod 600 ~/.ssh/config

    # 分发公钥到所有节点
    log_info "分发SSH公钥到所有节点..."
    local failed_nodes=()

    for server_ip in "${all_nodes[@]}"; do
        log_info "配置到节点: $server_ip"

        if [ -n "$node_password" ]; then
            # 使用密码自动认证
            if distribute_ssh_key_with_password "$server_ip" "$node_password" "$HOME/.ssh/id_rsa.pub"; then
                log_success "SSH公钥自动分发成功: $server_ip"
            else
                # 尝试手动方式
                if manual_distribute_ssh_key "$server_ip" "$node_password" "$ssh_key_content"; then
                    log_success "SSH公钥手动分发成功: $server_ip"
                else
                    log_error "SSH公钥分发失败: $server_ip"
                    failed_nodes+=("$server_ip")
                    continue
                fi
            fi
        else
            # 没有密码，尝试免密方式
            if ssh-copy-id -i ~/.ssh/id_rsa.pub root@"$server_ip" >/dev/null 2>&1; then
                log_success "SSH公钥分发成功: $server_ip"
            else
                log_error "SSH公钥分发失败: $server_ip (需要密码认证)"
                failed_nodes+=("$server_ip")
                continue
            fi
        fi

        # 测试免密登录
        if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$server_ip" "echo 'SSH test successful'" >/dev/null 2>&1; then
            log_success "SSH免密登录测试成功: $server_ip"
        else
            log_error "SSH免密登录测试失败: $server_ip"
            failed_nodes+=("$server_ip")
        fi
    done

    # 配置节点间相互免密登录
    log_info "配置节点间相互免密登录..."

    # 在每个节点上复制其他节点的公钥
    for server_ip in "${all_nodes[@]}"; do
        log_info "在节点 $server_ip 配置其他节点的SSH访问"

        # 将当前节点的公钥分发到其他节点
        for other_ip in "${all_nodes[@]}"; do
            if [ "$server_ip" != "$other_ip" ]; then
                # 获取其他节点的公钥
                local remote_pubkey=$(ssh root@"$other_ip" "cat ~/.ssh/id_rsa.pub" 2>/dev/null)
                if [ -n "$remote_pubkey" ]; then
                    # 添加到当前节点的authorized_keys
                    ssh_execute "$server_ip" "echo '$remote_pubkey' >> ~/.ssh/authorized_keys" >/dev/null 2>&1
                fi
            fi
        done

        # 确保authorized_keys权限正确
        ssh_execute "$server_ip" "chmod 600 ~/.ssh/authorized_keys" >/dev/null 2>&1
    done

    # 测试所有节点的免密登录
    log_info "测试所有节点间的SSH免密登录..."
    for server_ip in "${all_nodes[@]}"; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$server_ip" "hostname && date" >/dev/null 2>&1; then
            log_success "SSH免密登录测试成功: $server_ip"
        else
            log_error "SSH免密登录测试失败: $server_ip"
            failed_nodes+=("$server_ip")
        fi
    done

    # 检查结果
    if [ ${#failed_nodes[@]} -eq 0 ]; then
        save_stage_status "ssh_keyless" "success" "SSH免密登录配置完成 (${#all_nodes[@]} 个节点)"
        log_success "所有节点SSH免密登录配置完成"
        return 0
    else
        log_error "部分节点SSH免密登录配置失败: ${#failed_nodes[@]} 个节点"
        log_error "失败节点: ${failed_nodes[*]}"
        save_stage_status "ssh_keyless" "failed" "部分节点SSH免密登录配置失败"
        return 1
    fi
}

# 配置主机名和hosts文件 (基于config.yaml)
configure_hostname_hosts() {
    local config_file="${CONFIG_FILE:-config.yaml}"

    log_info "开始配置主机名和hosts文件 (基于配置: $config_file)"
    save_stage_status "hostname_hosts" "in_progress" "配置主机名和hosts"

    # 检查配置文件和yq工具
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        save_stage_status "hostname_hosts" "failed" "配置文件不存在"
        return 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq工具未安装，请先安装yq"
        save_stage_status "hostname_hosts" "failed" "yq工具未安装"
        return 1
    fi

    # 使用yq直接读取配置信息并生成hosts文件内容
    log_info "使用yq解析配置文件..."

    # 生成hosts文件内容
    local hosts_content="127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
"

    # 读取控制节点信息并添加到hosts文件
    local master_count=$(yq eval '.servers.master | length' "$config_file")
    for ((i=0; i<master_count; i++)); do
        local ip=$(yq eval ".servers.master[$i].ip" "$config_file")
        local hostname=$(yq eval ".servers.master[$i].hostname" "$config_file" | tr -d '"')
        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            log_error "控制节点 $ip 缺少hostname配置，请检查config.yaml"
            continue
        fi
        hosts_content+="$ip   $hostname
"
    done

    # 读取工作节点信息并添加到hosts文件
    local worker_count=$(yq eval '.servers.workers | length' "$config_file")
    for ((i=0; i<worker_count; i++)); do
        local ip=$(yq eval ".servers.workers[$i].ip" "$config_file")
        local hostname=$(yq eval ".servers.workers[$i].hostname" "$config_file" | tr -d '"')
        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            log_error "工作节点 $ip 缺少hostname配置，请检查config.yaml"
            continue
        fi
        hosts_content+="$ip   $hostname
"
    done

    # 读取镜像仓库节点信息并添加到hosts文件
    local registry_count=$(yq eval '.servers.registry | length' "$config_file")
    for ((i=0; i<registry_count; i++)); do
        local ip=$(yq eval ".servers.registry[$i].ip" "$config_file")
        local hostname=$(yq eval ".servers.registry[$i].hostname" "$config_file" | tr -d '"')
        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            log_error "镜像仓库节点 $ip 缺少hostname配置，请检查config.yaml"
            continue
        fi
        hosts_content+="$ip   $hostname
"
    done

    # 创建临时hosts文件
    local temp_hosts_file="/tmp/kubeeasy_hosts_$$"
    echo "$hosts_content" > "$temp_hosts_file"

    log_info "生成的hosts文件内容:"
    echo "================================"
    cat "$temp_hosts_file"
    echo "================================"

    # 统计节点数量
    local total_nodes=$((master_count + worker_count + registry_count))
    log_info "发现服务器总数: $total_nodes"
    log_info "控制节点: $master_count 个"
    log_info "工作节点: $worker_count 个"
    log_info "镜像仓库节点: $registry_count 个"

    # 合并所有节点IP用于分发hosts文件
    local all_ips=()

    # 收集所有节点IP
    for ((i=0; i<master_count; i++)); do
        all_ips+=($(yq eval ".servers.master[$i].ip" "$config_file"))
    done
    for ((i=0; i<worker_count; i++)); do
        all_ips+=($(yq eval ".servers.workers[$i].ip" "$config_file"))
    done
    for ((i=0; i<registry_count; i++)); do
        all_ips+=($(yq eval ".servers.registry[$i].ip" "$config_file"))
    done

    # 分发hosts文件到所有节点
    log_info "分发hosts文件到所有节点..."
    local failed_hosts=()
    for server_ip in "${all_ips[@]}"; do
        if distribute_file "$temp_hosts_file" "/etc/hosts" "$server_ip"; then
            log_success "hosts文件分发成功: $server_ip"
        else
            log_error "hosts文件分发失败: $server_ip"
            failed_hosts+=("$server_ip")
        fi
    done

    # 配置控制节点主机名
    log_info "配置控制节点主机名..."
    for ((i=0; i<master_count; i++)); do
        local server_ip=$(yq eval ".servers.master[$i].ip" "$config_file")
        local hostname=$(yq eval ".servers.master[$i].hostname" "$config_file" | tr -d '"')

        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            log_error "跳过控制节点 $server_ip：缺少hostname配置"
            failed_hosts+=("$server_ip")
            continue
        fi

        log_info "配置控制节点: $server_ip -> $hostname"
        if ssh_execute_check "$server_ip" "hostnamectl set-hostname $hostname" "设置主机名: $hostname"; then
            log_success "控制节点主机名设置成功: $server_ip -> $hostname"
        else
            log_error "控制节点主机名设置失败: $server_ip -> $hostname"
            failed_hosts+=("$server_ip")
        fi
    done

    # 配置工作节点主机名
    log_info "配置工作节点主机名..."
    for ((i=0; i<worker_count; i++)); do
        local server_ip=$(yq eval ".servers.workers[$i].ip" "$config_file")
        local hostname=$(yq eval ".servers.workers[$i].hostname" "$config_file" | tr -d '"')

        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            log_error "跳过工作节点 $server_ip：缺少hostname配置"
            failed_hosts+=("$server_ip")
            continue
        fi

        log_info "配置工作节点: $server_ip -> $hostname"
        if ssh_execute_check "$server_ip" "hostnamectl set-hostname $hostname" "设置主机名: $hostname"; then
            log_success "工作节点主机名设置成功: $server_ip -> $hostname"
        else
            log_error "工作节点主机名设置失败: $server_ip -> $hostname"
            failed_hosts+=("$server_ip")
        fi
    done

    # 配置镜像仓库节点主机名
    log_info "配置镜像仓库节点主机名..."
    for ((i=0; i<registry_count; i++)); do
        local server_ip=$(yq eval ".servers.registry[$i].ip" "$config_file")
        local hostname=$(yq eval ".servers.registry[$i].hostname" "$config_file" | tr -d '"')

        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            log_error "跳过镜像仓库节点 $server_ip：缺少hostname配置"
            failed_hosts+=("$server_ip")
            continue
        fi

        log_info "配置镜像仓库节点: $server_ip -> $hostname"
        if ssh_execute_check "$server_ip" "hostnamectl set-hostname $hostname" "设置主机名: $hostname"; then
            log_success "镜像仓库节点主机名设置成功: $server_ip -> $hostname"
        else
            log_error "镜像仓库节点主机名设置失败: $server_ip -> $hostname"
            failed_hosts+=("$server_ip")
        fi
    done

    # 清理临时文件
    rm -f "$temp_hosts_file"

    # 检查结果
    if [ ${#failed_hosts[@]} -eq 0 ]; then
        save_stage_status "hostname_hosts" "success" "主机名和hosts配置完成 ($total_nodes 个节点)"
        log_success "所有节点主机名和hosts配置完成"
        return 0
    else
        log_error "部分节点配置失败: ${#failed_hosts[@]} 个节点"
        log_error "失败节点: ${failed_hosts[*]}"
        save_stage_status "hostname_hosts" "failed" "部分节点配置失败"
        return 1
    fi
}

# 配置环境变量
configure_environment() {
    if is_stage_completed "environment"; then
        log_info "环境配置已完成，跳过"
        return 0
    fi

    log_info "开始配置环境变量"
    save_stage_status "environment" "in_progress" "配置环境变量"

    # 并发配置所有节点的环境变量
    if ssh_execute_script_batch "${k8s_nodes[@]}" \
        "$data_path/06.InstallScrpit/01.set-env.sh" \
        "$data_path" "配置环境变量" true; then

        save_stage_status "environment" "success" "环境变量配置完成"
        return 0
    else
        save_stage_status "environment" "failed" "环境变量配置失败"
        return 1
    fi
}

# 配置DNS
configure_dns() {
    if is_stage_completed "dns"; then
        log_info "DNS配置已完成，跳过"
        return 0
    fi

    log_info "开始配置DNS"
    save_stage_status "dns" "in_progress" "配置DNS"

    # 并发配置所有节点的DNS
    if ssh_execute_script_batch "${k8s_nodes[@]}" \
        "$data_path/06.InstallScrpit/01.dns.sh" \
        "$dns_ip" "配置DNS" true; then

        save_stage_status "dns" "success" "DNS配置完成"
        return 0
    else
        save_stage_status "dns" "failed" "DNS配置失败"
        return 1
    fi
}

# 检查Docker是否已安装
check_docker_installed() {
    local server="$1"
    check_remote_command "$server" "docker info | wc -l" "53"
}

# 安装Docker (for K8s v1.23.17)
install_docker() {
    if is_stage_completed "docker"; then
        log_info "Docker安装已完成，跳过"
        return 0
    fi

    log_info "开始安装Docker"
    save_stage_status "docker" "in_progress" "安装Docker"

    # 解压Docker安装包
    log_info "解压Docker安装包"
    tar -xzf "$data_path/02.install_package/docker-20.10.24.tgz" -C "$data_path/02.install_package/"
    exit_status_check "Docker安装包解压" || return 1

    # 分发Docker二进制文件
    distribute_file "$data_path/02.install_package/docker" "/usr/bin" "${all_nodes[@]}"

    # 串行配置Docker服务 (避免并发可能导致的问题)
    for server_ip in "${all_nodes[@]}"; do
        if ! check_docker_installed "$server_ip"; then
            log_info "在节点 $server_ip 配置Docker服务"
            if ssh_execute_script "$server_ip" "$data_path/06.InstallScrpit/02.docker_install.sh" "$registry_ip" "配置Docker"; then
                if check_docker_installed "$server_ip"; then
                    log_success "Docker在节点 $server_ip 安装成功"
                else
                    log_error "Docker在节点 $server_ip 安装失败"
                    save_stage_status "docker" "failed" "Docker安装失败: $server_ip"
                    return 1
                fi
            else
                log_error "Docker配置失败: $server_ip"
                save_stage_status "docker" "failed" "Docker配置失败: $server_ip"
                return 1
            fi
        else
            log_info "Docker已在节点 $server_ip 安装"
        fi
    done

    save_stage_status "docker" "success" "Docker安装完成"
    return 0
}

# 检查Containerd是否已安装
check_containerd_installed() {
    local server="$1"
    ssh_execute "$server" "containerd --version" >/dev/null 2>&1
}

# 安装Containerd (for K8s v1.30.14)
install_containerd() {
    if is_stage_completed "containerd"; then
        log_info "Containerd安装已完成，跳过"
        return 0
    fi

    log_info "开始安装Containerd"
    save_stage_status "containerd" "in_progress" "安装Containerd"

    # 解压Containerd安装包
    log_info "解压Containerd安装包"
    tar -xzf "$data_path/02.install_package/containerd-1.7.18-linux-amd64.tar.gz" -C /usr/local/
    exit_status_check "Containerd安装包解压" || return 1

    # 分发Containerd二进制文件到所有节点
    log_info "分发Containerd二进制文件到所有节点"
    for server_ip in "${all_nodes[@]}"; do
        if ! check_containerd_installed "$server_ip"; then
            # 复制containerd二进制文件
            scp -r /usr/local/bin/containerd* root@$server_ip:/usr/local/bin/
            scp -r /usr/local/sbin/runc root@$server_ip:/usr/local/sbin/
            scp -r /usr/local/bin/ctr root@$server_ip:/usr/local/bin/

            log_info "在节点 $server_ip 配置Containerd服务"
            if ssh_execute_script "$server_ip" "$data_path/06.InstallScrpit/02.containerd_install.sh" "$registry_ip" "配置Containerd"; then
                if check_containerd_installed "$server_ip"; then
                    log_success "Containerd在节点 $server_ip 安装成功"
                else
                    log_error "Containerd在节点 $server_ip 安装失败"
                    save_stage_status "containerd" "failed" "Containerd安装失败: $server_ip"
                    return 1
                fi
            else
                log_error "Containerd配置失败: $server_ip"
                save_stage_status "containerd" "failed" "Containerd配置失败: $server_ip"
                return 1
            fi
        else
            log_info "Containerd已在节点 $server_ip 安装"
        fi
    done

    save_stage_status "containerd" "success" "Containerd安装完成"
    return 0
}

# 容器运行时安装函数 (根据K8s版本选择)
install_container_runtime() {
    # 从config.yaml读取K8s版本
    local k8s_version=$(yq eval '.cluster.version' "${CONFIG_FILE:-config.yaml}" | tr -d '"')
    log_info "检测到Kubernetes版本: $k8s_version"

    case "$k8s_version" in
        "v1.23.17")
            log_info "为K8s v1.23.17安装Docker作为容器运行时"
            install_docker
            ;;
        "v1.30.14")
            log_info "为K8s v1.30.14安装Containerd作为容器运行时"
            install_containerd
            ;;
        *)
            log_error "不支持的Kubernetes版本: $k8s_version"
            log_error "支持的版本: v1.23.17 (Docker), v1.30.14 (Containerd)"
            return 1
            ;;
    esac
}

# 拉取K8s基础镜像
pull_k8s_images() {
    log_info "开始拉取K8s基础镜像"

    # Docker登录 (在本地执行)
    docker login registry:5000 -u "$registry_user" -p "$registry_passwd" >/dev/null 2>&1

    # 定义需要拉取的镜像
    local images=(
        "registry:5000/google_containers/pause:3.6"
        "registry:5000/google_containers/kube-proxy:v1.23.17"
        "registry:5000/google_containers/coredns:v1.8.6"
    )

    # 并发拉取镜像
    local pids=()

    for server_ip in "${k8s_nodes[@]}"; do
        (
            log_info "$server_ip: Docker登录并拉取镜像"

            # Docker登录
            ssh_execute "$server_ip" "docker login registry:5000 -u $registry_user -p $registry_passwd"

            # 拉取所有镜像
            local success=true
            for image in "${images[@]}"; do
                if ! ssh_execute "$server_ip" "docker pull $image"; then
                    log_error "拉取镜像失败: $image on $server_ip"
                    success=false
                fi
            done

            if [ "$success" = "true" ]; then
                log_success "节点 $server_ip 镜像拉取完成"
            else
                log_error "节点 $server_ip 镜像拉取失败"
            fi
        ) &
        pids+=($!)
    done

    # 等待所有拉取完成
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    log_success "K8s基础镜像拉取完成"
}

# 安装K8s依赖包
install_k8s_dependencies() {
    if is_stage_completed "dependencies"; then
        log_info "K8s依赖包已安装，跳过"
        return 0
    fi

    log_info "开始安装K8s依赖包"
    save_stage_status "dependencies" "in_progress" "安装K8s依赖包"

    # 分发依赖包
    distribute_file "$data_path/01.rpm_package/kubelet" "/tmp" "${k8s_nodes[@]}"

    # 并发安装依赖包
    if ssh_execute_script_batch "${k8s_nodes[@]}" \
        "$data_path/06.InstallScrpit/04.Dependency-Package-rpm.sh" \
        "" "安装K8s依赖包" true; then

        save_stage_status "dependencies" "success" "K8s依赖包安装完成"
        return 0
    else
        save_stage_status "dependencies" "failed" "K8s依赖包安装失败"
        return 1
    fi
}

#=============================================================================
# 主安装流程
#=============================================================================

# 主安装函数
main() {
    local config_file="${1:-config.yaml}"

    log_info "开始 KubeEasy Kubernetes 集群安装"
    log_info "配置文件: $config_file"

    # 环境检查
    log_info "第一步: 环境检查和工具安装"
    if ! check_system_environment; then
        log_error "环境检查失败，脚本退出"
        exit 1
    fi

    # 加载配置
    load_config "$config_file"

    # 初始化节点变量
    initialize_node_variables

    # 验证配置
    validate_config

    # 初始化hosts文件
    initialize_hosts_file

    # 执行安装步骤
    log_info "第二步: 配置主机名和hosts文件"
    if ! configure_hostname_hosts; then
        log_error "安装失败在步骤: 配置主机名和hosts文件"
        exit 1
    fi

    log_info "第三步: 配置SSH免密登录"
    if ! setup_ssh_keyless; then
        log_error "安装失败在步骤: 配置SSH免密登录"
        exit 1
    fi

    log_info "第四步: 配置环境变量"
    if ! configure_environment; then
        log_error "安装失败在步骤: 配置环境变量"
        exit 1
    fi

    log_info "第五步: 配置DNS服务"
    if ! configure_dns; then
        log_error "安装失败在步骤: 配置DNS服务"
        exit 1
    fi

    log_info "第六步: 安装容器运行时"
    if ! install_container_runtime; then
        log_error "安装失败在步骤: 安装容器运行时"
        exit 1
    fi

    log_info "第七步: 安装镜像仓库"
    if ! install_registry; then
        log_error "安装失败在步骤: 安装镜像仓库"
        exit 1
    fi

    log_info "第八步: 安装K8s依赖包"
    if ! install_k8s_dependencies; then
        log_error "安装失败在步骤: 安装K8s依赖包"
        exit 1
    fi

    log_info "第九步: 拉取K8s基础镜像"
    if ! pull_k8s_images; then
        log_error "安装失败在步骤: 拉取K8s基础镜像"
        exit 1
    fi

    log_info "第十步: 初始化集群"
    if ! init_cluster; then
        log_error "安装失败在步骤: 初始化集群"
        exit 1
    fi

    log_info "第十一步: 加入主控节点"
    if ! join_master_nodes; then
        log_error "安装失败在步骤: 加入主控节点"
        exit 1
    fi

    log_info "第十二步: 加入工作节点"
    if ! join_worker_nodes; then
        log_error "安装失败在步骤: 加入工作节点"
        exit 1
    fi

    log_info "第十三步: 配置网络组件"
    if ! configure_network; then
        log_error "安装失败在步骤: 配置网络组件"
        exit 1
    fi

    log_info "第十四步: 配置存储组件"
    if ! configure_storage; then
        log_error "安装失败在步骤: 配置存储组件"
        exit 1
    fi

    log_info "第十五步: 安装集群插件"
    if ! install_addons; then
        log_error "安装失败在步骤: 安装集群插件"
        exit 1
    fi

    log_success "KubeEasy Kubernetes 集群安装完成!"
}

# 脚本入口点
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi