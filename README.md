# springboot-demo 部署仓库（GitOps）

这个仓库只放**"集群应该长什么样"**，不放应用代码，也不放 Jenkins 的构建逻辑。

应用镜像由 Jenkins 构建后推到 Harbor（项目 `demo`），CI 再把新版本写进这里的 overlay；Argo CD 盯着这个仓库，发现清单变了就同步到集群。

```
.
├── base/                     # 所有环境共享的资源定义
│   ├── kustomization.yaml
│   ├── sql/                  # MySQL 初始化脚本模板（口令是占位符）
│   ├── mysql-master.yaml     # StatefulSet + PVC + 探针 + 资源限制
│   ├── mysql-slave.yaml
│   ├── redis.yaml            # StatefulSet + AOF + PVC
│   ├── backend.yaml          # 2 副本起，滚动更新 maxUnavailable=0
│   └── frontend.yaml
├── overlays/
│   ├── dev/                  # 命名空间 demo-dev，2 副本，HTTP Ingress
│   └── prod/                 # 命名空间 demo-prod，3 副本，digest 固定，HTTPS Ingress，PDB
├── infra/                    # 一次性安装的集群基础设施（存储类 + Ingress 控制器）
└── scripts/
    └── bootstrap-namespace.sh # 初始化 Secret（口令、拉取凭据、TLS 证书）
```

## 环境对照

| 项 | dev | prod |
|---|---|---|
| 命名空间 | `demo-dev` | `demo-prod` |
| 访问地址 | `http://demo-dev.local` | `https://demo.local` |
| backend / frontend 副本 | 2 / 2 | 3 / 3 |
| 镜像引用 | `newTag: <git sha>` | `digest: sha256:...`（不可变） |
| 同步方式 | Argo 自动同步（CI 也会主动触发） | Argo 手动 Sync（人工审批） |
| 额外保护 | — | PDB（minAvailable=2）、更大 resources |

## 数据与配置

- MySQL 主/从都是 **StatefulSet + PVC（8Gi，storageClass `local-path`）**，Pod 重建不丢数据，`init.sql` 只在**首次**初始化时执行。
- Redis 是 **StatefulSet + PVC（1Gi）+ AOF**，重启后缓存可恢复，不会一重启就把流量全打到数据库。
- 所有口令都在 Secret 里，**仓库里没有明文**：`mysql-secret`（root / repl / app）、`redis-secret`、`harbor-pull`、`demo-tls`。
- MySQL 初始化脚本里的 `__REPL_PASS__` 等占位符，由 initContainer 读取 Secret 后渲染成真正的 SQL，再交给官方镜像的 initdb 流程。

## 第一次部署的顺序

```bash
# 0) 集群基础设施（只需一次）：动态存储类 + Traefik Ingress
kubectl apply -f infra/00-local-path-storage.yaml
kubectl apply -f infra/01-traefik-ingress.yaml

# 1) 每个环境初始化 Secret（口令/拉取凭据/证书）
HARBOR_ROBOT_USER='robot$demo+readonly-puller' HARBOR_ROBOT_PASS='<secret>' \
  ./scripts/bootstrap-namespace.sh demo-dev
HARBOR_ROBOT_USER='robot$demo+readonly-puller' HARBOR_ROBOT_PASS='<secret>' \
  ./scripts/bootstrap-namespace.sh demo-prod

# 2) 本地预渲染检查（只看渲染结果，不落盘）
kubectl kustomize overlays/dev  | head -40
kubectl kustomize overlays/prod | grep -E "image:|replicas"

# 3) 交给 Argo CD（Application 的创建方式见应用仓库 docs/production-grade.md）
```

## CI 怎么改这个仓库

Jenkins 流水线只改 overlay 里的两行镜像引用：

- `dev`：`newTag: "<git 短提交号>"`（好排查"线上跑的是哪个提交"）
- `prod`：`digest: "sha256:..."`（tag 被覆盖也换不掉线上版本）

提交信息固定为 `ci(<env>): springboot-demo -> <tag>`，回滚就是 `git revert` 这一条。

## 生产化取舍说明（诚实版）

已做到：私有仓库 + 只读拉取凭据、StatefulSet + PVC 持久化、startup/readiness/liveness 三段探针、requests/limits、PDB、HTTPS Ingress、镜像 digest 固定、口令不进 Git、多环境 overlay。

仍受单节点实验环境限制、**没有做**的：

- 镜像签名（cosign）与准入校验：需要密钥托管/KMS，实验环境没有对应基础设施，暂以 Harbor 的 Trivy 扫描 + CI Critical 阻断代替。
- MySQL 多副本高可用（Group Replication / Orchestrator）：单节点集群做不出真正的故障转移。
- 日志与指标采集（Loki / Prometheus）：另行部署，不塞进业务仓库。
- 自动伸缩（HPA）：集群没装 metrics-server，加了也不会生效，故未启用。
