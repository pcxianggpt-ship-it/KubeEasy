#!/bin/bash

# 定义服务器的用户、IP地址或主机名
SERVERS=("$@")

echo $SERVERS

# SSH端口，默认22
PORT="22"

# 本地SSH公钥文件路径
PUB_KEY_PATH="$HOME/.ssh/id_rsa.pub"

# 生成密钥对（如果不存在）
generate_key_if_not_exist() {
  if [ ! -f "$PUB_KEY_PATH" ]; then
    echo "SSH密钥对不存在，正在生成..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
  fi
}

# 分发公钥到其他服务器
distribute_key() {
  for server in "${SERVERS[@]}"; do
    echo "正在将公钥复制到 $server ..."
    ssh "root@$server" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < "$PUB_KEY_PATH"
  done
}

# 每台服务器相互分发公钥
distribute_keys_between_servers() {
  for source_server in "${SERVERS[@]}"; do
    echo "正在从 $source_server 分发公钥到其他服务器..."
    for target_server in "${SERVERS[@]}"; do
      if [ "$source_server" != "$target_server" ]; then
        ssh "root@$source_server" "ssh root@$target_server 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'" < "$PUB_KEY_PATH"
      fi
    done
  done
}

# 主函数
main() {
  eval "$(ssh-agent -s)"  # 启动ssh-agent
  ssh-add ~/.ssh/id_rsa  # 将私钥添加到ssh-agent

  generate_key_if_not_exist
  distribute_key
  distribute_keys_between_servers
  
  echo "所有服务器之间的免密登录已配置完成！"
  
  ssh-agent -k  # 关闭ssh-agent
}

main

