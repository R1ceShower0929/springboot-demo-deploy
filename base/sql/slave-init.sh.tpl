#!/bin/bash
# 从库初始化：等主库就绪 -> 从最早的 binlog 起点建立复制（这样建库/建表/种子数据都会重放）
# -> 打开只读，防止误写从库
set -e

echo "[slave] waiting for master ..."
until mysqladmin ping -h mysql-master -uroot -p__ROOT_PASS__ --silent 2>/dev/null; do
  sleep 2
done
echo "[slave] master is ready"

# 关键：取主库第一个 binlog 文件，从 pos=4 开始重放。
# 不指定 SOURCE_LOG_FILE/POS 时，CHANGE REPLICATION 默认从"当前 binlog 末尾"开始，
# 初始化阶段创建的库、表和种子数据永远同步不过来。
FIRST_LOG=$(mysql -h mysql-master -uroot -p__ROOT_PASS__ -N -e "SHOW BINARY LOGS" 2>/dev/null | head -1 | awk '{print $1}')
echo "[slave] replay binlog from ${FIRST_LOG}:4"

mysql -uroot -p__ROOT_PASS__ <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-master',
  SOURCE_PORT=3306,
  SOURCE_USER='repl',
  SOURCE_PASSWORD='__REPL_PASS__',
  SOURCE_LOG_FILE='${FIRST_LOG}',
  SOURCE_LOG_POS=4,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL

# 等复制线程真正跑起来
for i in $(seq 1 30); do
  status=$(mysql -uroot -p__ROOT_PASS__ -e "SHOW REPLICA STATUS\G" 2>/dev/null || true)
  if echo "$status" | grep -q "Replica_IO_Running: Yes" && echo "$status" | grep -q "Replica_SQL_Running: Yes"; then
    echo "[slave] replication running"
    break
  fi
  sleep 2
done

# 复制建好后把从库设为只读（复制线程有 SUPER 权限，仍可写入）
# 只读由 replica.cnf 中的 read_only=ON + 应用账号无 SUPER 权限共同保证
echo "[slave] replication configured (read_only from replica.cnf)"
