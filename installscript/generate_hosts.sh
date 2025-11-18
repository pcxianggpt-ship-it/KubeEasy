#!/bin/bash

# 原始hosts文件路径
input_file="/etc/hosts"
# 输出的hostsname.sh文件路径
output_file="/tmp/hostsname.sh"

# 清空或创建hostsname.sh文件
> "$output_file"

# 逐行读取hosts文件并处理
while read -r line; do
  # 跳过空行
  [ -z "$line" ] && continue
  
  # 提取IP和主机名
  ip=$(echo "$line" | awk '{print $1}')
  hostname=$(echo "$line" | awk '{print $2}')
  
  # 写入格式化内容到hostsname.sh文件
  echo "export ${hostname}_ip=${ip}" >> "$output_file"
done < "$input_file"

echo "生成完成：$output_file"
