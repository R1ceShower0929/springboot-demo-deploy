#!/usr/bin/env bash
# 为一个环境命名空间初始化"不能进 Git 的东西"：
#   - mysql-secret   : 数据库口令
#   - redis-secret   : Redis 口令
#   - harbor-pull    : 拉私有镜像用的 dockerconfigjson
#   - demo-tls       : Ingress 用的 TLS 证书
#
# 用法：
#   HARBOR_ROBOT_USER='robot$demo+readonly-puller' \
#   HARBOR_ROBOT_PASS='<robot 的 secret>' \
#   TLS_CERT=tls.crt TLS_KEY=tls.key \
#   ./scripts/bootstrap-namespace.sh demo-dev
#
# 已存在的 secret 不会被覆盖（避免每次跑脚本就把口令换掉、把 Pod 打挂）。
set -euo pipefail

NS="${1:?用法: bootstrap-namespace.sh <namespace>}"
HARBOR_HOST="${HARBOR_HOST:-harbor.local}"
TLS_CERT="${TLS_CERT:-tls.crt}"
TLS_KEY="${TLS_KEY:-tls.key}"

echo "== 命名空间 $NS =="
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

have() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

rand() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20; }

if have mysql-secret; then
  echo "mysql-secret 已存在，跳过"
else
  ROOT_PASS="${MYSQL_ROOT_PASSWORD:-$(rand)}"
  REPL_PASS="${MYSQL_REPL_PASSWORD:-$(rand)}"
  APP_USER="${MYSQL_APP_USERNAME:-demo}"
  APP_PASS="${MYSQL_APP_PASSWORD:-$(rand)}"
  kubectl -n "$NS" create secret generic mysql-secret \
    --from-literal=root-password="$ROOT_PASS" \
    --from-literal=repl-password="$REPL_PASS" \
    --from-literal=app-username="$APP_USER" \
    --from-literal=app-password="$APP_PASS" >/dev/null
  echo "mysql-secret 已创建（口令只存在集群里）"
fi

if have redis-secret; then
  echo "redis-secret 已存在，跳过"
else
  kubectl -n "$NS" create secret generic redis-secret \
    --from-literal=password="${REDIS_PASSWORD:-$(rand)}" >/dev/null
  echo "redis-secret 已创建"
fi

if have harbor-pull; then
  echo "harbor-pull 已存在，跳过"
else
  : "${HARBOR_ROBOT_USER:?需要 HARBOR_ROBOT_USER（Harbor 项目 robot 账号）}"
  : "${HARBOR_ROBOT_PASS:?需要 HARBOR_ROBOT_PASS}"
  kubectl -n "$NS" create secret docker-registry harbor-pull \
    --docker-server="$HARBOR_HOST" \
    --docker-username="$HARBOR_ROBOT_USER" \
    --docker-password="$HARBOR_ROBOT_PASS" >/dev/null
  echo "harbor-pull 已创建（只读 robot，只能拉不能推）"
fi

if have demo-tls; then
  echo "demo-tls 已存在，跳过"
else
  [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ] || { echo "缺少证书文件：$TLS_CERT / $TLS_KEY"; exit 1; }
  kubectl -n "$NS" create secret tls demo-tls --cert="$TLS_CERT" --key="$TLS_KEY" >/dev/null
  echo "demo-tls 已创建"
fi

echo "== $NS 完成 =="
kubectl -n "$NS" get secret | sed -n '1,10p'
