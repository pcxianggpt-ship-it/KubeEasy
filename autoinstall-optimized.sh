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
    source "$config_file"
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

# 配置主机名和hosts文件 (基于config.yaml)
configure_hostname_hosts() {
    local config_file="${CONFIG_FILE:-config.yaml}"

    log_info "开始配置主机名和hosts文件 (基于配置: $config_file)"
    save_stage_status "hostname_hosts" "in_progress" "配置主机名和hosts"

    # 检查配置文件是否存在
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        save_stage_status "hostname_hosts" "failed" "配置文件不存在"
        return 1
    fi

    # 生成hosts文件内容
    local hosts_content=$(generate_hosts_content "$config_file")

    # 创建临时hosts文件
    local temp_hosts_file="/tmp/kubeeasy_hosts_$$"
    echo "$hosts_content" > "$temp_hosts_file"

    log_info "生成的hosts文件内容:"
    echo "================================"
    cat "$temp_hosts_file"
    echo "================================"

    # 解析服务器列表
    local master_result=$(parse_server_list "$config_file" "master")
    local master_ips=($(echo "$master_result" | cut -d'|' -f1))
    local master_hostnames=($(echo "$master_result" | cut -d'|' -f2))

    local worker_result=$(parse_server_list "$config_file" "workers")
    local worker_ips=($(echo "$worker_result" | cut -d'|' -f1))
    local worker_hostnames=($(echo "$worker_result" | cut -d'|' -f2))

    local registry_result=$(parse_server_list "$config_file" "registry")
    local registry_ips=($(echo "$registry_result" | cut -d'|' -f1))
    local registry_hostnames=($(echo "$registry_result" | cut -d'|' -f2))

    # 合并所有服务器IP
    local all_ips=("${master_ips[@]}" "${worker_ips[@]}" "${registry_ips[@]}")

    log_info "发现服务器总数: ${#all_ips[@]}"
    log_info "控制节点: ${#master_ips[@]} 个"
    log_info "工作节点: ${#worker_ips[@]} 个"
    log_info "镜像仓库节点: ${#registry_ips[@]} 个"

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
    for ((i=0; i<${#master_ips[@]}; i++)); do
        local server_ip="${master_ips[$i]}"
        local hostname="${master_hostnames[$i]}"

        if [ -z "$hostname" ]; then
            hostname="k8sc$((i+1))"
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
    for ((i=0; i<${#worker_ips[@]}; i++)); do
        local server_ip="${worker_ips[$i]}"
        local hostname="${worker_hostnames[$i]}"

        if [ -z "$hostname" ]; then
            hostname="k8sw$((i+1))"
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
    for ((i=0; i<${#registry_ips[@]}; i++)); do
        local server_ip="${registry_ips[$i]}"
        local hostname="${registry_hostnames[$i]}"

        if [ -z "$hostname" ]; then
            hostname="registry"
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
        save_stage_status "hostname_hosts" "success" "主机名和hosts配置完成 (${#all_ips[@]} 个节点)"
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
        "/data/k8s_install/06.InstallScrpit/01.set-env.sh" \
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
        "/data/k8s_install/06.InstallScrpit/01.dns.sh" \
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

# 安装Docker
install_docker() {
    if is_stage_completed "docker"; then
        log_info "Docker安装已完成，跳过"
        return 0
    fi

    log_info "开始安装Docker"
    save_stage_status "docker" "in_progress" "安装Docker"

    # 解压Docker安装包
    log_info "解压Docker安装包"
    tar -xzf /data/k8s_install/02.install_package/docker-20.10.24.tgz -C /data/k8s_install/02.install_package/
    exit_status_check "Docker安装包解压" || return 1

    # 分发Docker二进制文件
    distribute_file "/data/k8s_install/02.install_package/docker" "/usr/bin" "${all_nodes[@]}"

    # 串行配置Docker服务 (避免并发可能导致的问题)
    for server_ip in "${all_nodes[@]}"; do
        if ! check_docker_installed "$server_ip"; then
            log_info "在节点 $server_ip 配置Docker服务"
            if ssh_execute_script "$server_ip" "/data/k8s_install/06.InstallScrpit/02.docker_install.sh" "$registry_ip" "配置Docker"; then
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
    distribute_file "/data/k8s_install/01.rpm_package/kubelet" "/tmp" "${k8s_nodes[@]}"

    # 并发安装依赖包
    if ssh_execute_script_batch "${k8s_nodes[@]}" \
        "/data/k8s_install/06.InstallScrpit/04.Dependency-Package-rpm.sh" \
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

    # 加载配置
    load_config "$config_file"

    # 验证配置
    validate_config

    # 初始化hosts文件
    initialize_hosts_file

    # 执行安装步骤
    local install_steps=(
        "configure_hostname_hosts"
        "setup_ssh_keyless"
        "configure_environment"
        "configure_dns"
        "install_docker"
        "install_registry"
        "install_k8s_dependencies"
        "pull_k8s_images"
        "init_cluster"
        "join_master_nodes"
        "join_worker_nodes"
        "configure_network"
        "configure_storage"
        "install_addons"
    )

    local current_step=1
    local total_steps=${#install_steps[@]}

    for step in "${install_steps[@]}"; do
        log_info "[$current_step/$total_steps] 执行步骤: $step"

        if ! $step; then
            log_error "安装失败在步骤: $step"
            exit 1
        fi

        current_step=$((current_step + 1))
    done

    log_success "KubeEasy Kubernetes 集群安装完成!"
}

# 脚本入口点
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi