#!/usr/bin/env bash
set -euo pipefail

HOSTS=("192.168.65.139" "192.168.65.141" "192.168.65.142" "192.168.65.143" "192.168.65.144" "192.168.65.145")
PASSWORD="Kylin123123"

TMPDIR="$(mktemp -d /tmp/sshcluster.XXXX)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

echo "开始生成 SSH 公钥并收集..."

gen_and_get_key() {
  local host="$1"
  expect <<EOF
set timeout 20
spawn ssh $SSH_OPTS root@$host "mkdir -p ~/.ssh && chmod 700 ~/.ssh && [ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa >/dev/null 2>&1; cat ~/.ssh/id_rsa.pub"
expect {
  "*yes/no*" {send "yes\r"; exp_continue}
  "*assword*" {send "$PASSWORD\r"}
}
expect eof
EOF
}

for h in "${HOSTS[@]}"; do
  echo "生成 $h 的公钥..."
  gen_and_get_key "$h" > "$TMPDIR/$h.pub"
done

cat "$TMPDIR"/*.pub | sort -u > "$TMPDIR/all.pub"

echo "开始分发公钥..."
for h in "${HOSTS[@]}"; do
expect <<EOF
set timeout 20
spawn scp $SSH_OPTS "$TMPDIR/all.pub" root@$h:/tmp/all.pub
expect {
  "*yes/no*" {send "yes\r"; exp_continue}
  "*assword*" {send "$PASSWORD\r"}
}
expect eof
EOF

expect <<EOF
set timeout 20
spawn ssh $SSH_OPTS root@$h "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && cat /tmp/all.pub ~/.ssh/authorized_keys | sort -u > /tmp/ak.tmp && mv /tmp/ak.tmp ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f /tmp/all.pub"
expect {
  "*yes/no*" {send "yes\r"; exp_continue}
  "*assword*" {send "$PASSWORD\r"}
}
expect eof
EOF
done

echo "✅ 所有主机互信已配置完成！"
