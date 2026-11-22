#!/bin/sh
# 把 MySQL 初始化模板里的占位符替换成 Secret 注入的环境变量，产出可执行的初始化脚本。
# 由 initContainer 调用，模板本身不含任何明文口令。
set -eu

tpl="$1"
out="$2"

: "${MYSQL_ROOT_PASSWORD:?缺少 MYSQL_ROOT_PASSWORD}"
: "${MYSQL_REPL_PASSWORD:?缺少 MYSQL_REPL_PASSWORD}"
: "${MYSQL_APP_USERNAME:?缺少 MYSQL_APP_USERNAME}"
: "${MYSQL_APP_PASSWORD:?缺少 MYSQL_APP_PASSWORD}"

sed -e "s|__ROOT_PASS__|${MYSQL_ROOT_PASSWORD}|g" \
    -e "s|__REPL_PASS__|${MYSQL_REPL_PASSWORD}|g" \
    -e "s|__APP_USER__|${MYSQL_APP_USERNAME}|g" \
    -e "s|__APP_PASS__|${MYSQL_APP_PASSWORD}|g" \
    "$tpl" > "$out"

if [ "${out##*.}" = "sh" ]; then
  chmod +x "$out"
fi

echo "[render-init] $tpl -> $out 完成"
