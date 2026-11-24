#!/usr/bin/env bash
# 一键核对"生产级七项"是否真的生效——只读，不改集群。
#
# 用法：
#   ./scripts/verify-production.sh dev
#   ./scripts/verify-production.sh prod
#
# 依赖：kubectl（能读集群）、curl。不需要 jq。
set -uo pipefail

ENV="${1:-dev}"
case "$ENV" in
  dev)  NS=demo-dev;  APP=demo-dev;  HOST=demo-dev.local;  SCHEME=http;  PORT=30880 ;;
  prod) NS=demo-prod; APP=demo-prod; HOST=demo.local;      SCHEME=https; PORT=30445 ;;
  *) echo "用法: $0 [dev|prod]"; exit 2 ;;
esac

ARGO_URL="${ARGO_URL:-https://172.17.0.1:30090}"
ARGO_TOKEN_FILE="${ARGO_TOKEN_FILE:-/root/argocd.token}"
TRG="${TARGET_IP:-172.17.0.1}"          # Traefik 所在的宿主地址
PASS=0; FAIL=0
ok()   { echo "  ✔ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✘ $*"; FAIL=$((FAIL+1)); }

echo "== 校验 $ENV 环境（namespace=$NS）=="

# 1. 工作负载是否全部就绪
total=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | wc -l)
notready=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$2 !~ /^[0-9]+\/[0-9]+/ || $3!="Running"' | wc -l)
if [ "$total" -gt 0 ] && [ "$notready" -eq 0 ]; then ok "工作负载 $total 个 Pod 全部 Running/Ready"; else bad "Pod 未全部就绪（$notready/$total 异常）"; fi

# 2. 镜像：dev 应是 git sha 的 tag，prod 必须钉在 digest 上
for d in backend frontend; do
  img=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  case "$ENV" in
    dev)  case "$img" in *:*) ok "$d 使用 tag：${img##*/}";; *) bad "$d 镜像未用 tag：$img";; esac ;;
    prod) case "$img" in *@sha256:*) ok "$d 固定在 digest：${img##*@}";; *) bad "$d 未用 digest 固定：$img";; esac ;;
  esac
done

# 3. 三段探针
for d in backend frontend; do
  n=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{range .spec.template.spec.containers[0]}{.startupProbe}{.readinessProbe}{.livenessProbe}{end}' 2>/dev/null | grep -o '"periodSeconds"' | wc -l)
  if [ "$n" -ge 3 ]; then ok "$d 三段探针齐备（startup/readiness/liveness）"; else bad "$d 探针不全（只找到 $n 段）"; fi
done

# 4. requests / limits
for d in backend frontend; do
  # jsonpath 输出的顺序不固定（limits 可能在前），所以两个关键字分别判
  rq=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].resources.requests}' 2>/dev/null)
  lm=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].resources.limits}' 2>/dev/null)
  if [ -n "$rq" ] && [ -n "$lm" ]; then ok "$d requests=$rq limits=$lm"; else bad "$d 缺少 requests/limits（requests=${rq:-空} limits=${lm:-空}）"; fi
done

# 5. 数据面持久化：PVC 必须 Bound
pvc_all=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | wc -l)
pvc_ok=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | awk '$2=="Bound"' | wc -l)
if [ "$pvc_all" -ge 3 ] && [ "$pvc_ok" -eq "$pvc_all" ]; then ok "MySQL/Redis PVC $pvc_ok/$pvc_all 已 Bound（不再是 emptyDir）"; else bad "PVC 未全部绑定（$pvc_ok/$pvc_all）"; fi

# 6. 生产 PDB
if [ "$ENV" = prod ]; then
  n=$(kubectl -n "$NS" get pdb --no-headers 2>/dev/null | wc -l)
  if [ "$n" -ge 2 ]; then ok "PDB 已存在：$(kubectl -n "$NS" get pdb --no-headers | awk '{printf "%s(minAvailable=%s) ", $1, $2}')"; else bad "缺少 PDB"; fi
fi

# 7. Ingress + HTTPS（prod 强制 TLS）
if kubectl -n "$NS" get ingress demo >/dev/null 2>&1; then ok "Ingress demo 存在（class=$(kubectl -n "$NS" get ingress demo -o jsonpath='{.spec.ingressClassName}')）"
else bad "Ingress demo 不存在"; fi
if [ "$ENV" = prod ]; then
  tls=$(kubectl -n "$NS" get ingress demo -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)
  [ -n "$tls" ] && ok "Ingress 启用 TLS（secret=$tls）" || bad "Ingress 未配置 TLS"
fi

# 8. 真实访问 + 读写分离
if [ "$ENV" = dev ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" "http://$TRG:$PORT/" || true)
else
  code=$(curl -s -o /dev/null -w '%{http_code}' -k --resolve "$HOST:$PORT:$TRG" "https://$HOST:$PORT/" || true)
fi
[ "$code" = 200 ] && ok "首页 HTTP $code（$SCHEME://$HOST:$PORT/）" || bad "首页返回 $code"

if [ "$ENV" = dev ]; then
  body=$(curl -s -H "Host: $HOST" "http://$TRG:$PORT/api/users/ping/datasource" || true)
else
  body=$(curl -s -k --resolve "$HOST:$PORT:$TRG" "https://$HOST:$PORT/api/users/ping/datasource" || true)
fi
case "$body" in *'"readDatasource":"slave"'*) ok "读走从库：$body";; *) bad "读写分离接口异常：${body:-无响应}";; esac

# 9. Argo CD 同步状态
if [ -r "$ARGO_TOKEN_FILE" ]; then
  st=$(curl -sk -H "Authorization: Bearer $(cat "$ARGO_TOKEN_FILE")" "$ARGO_URL/api/v1/applications/$APP" \
       | grep -o '"status":"[A-Za-z]*"' | head -1 | cut -d'"' -f4)
  [ "$st" = Synced ] && ok "Argo CD $APP = Synced" || bad "Argo CD $APP = ${st:-取不到}"
else
  echo "  - 跳过 Argo 检查（没有可读的 $ARGO_TOKEN_FILE）"
fi

echo
echo "== 结果：$PASS 项通过，$FAIL 项失败 =="
[ "$FAIL" -eq 0 ]
