# springboot-demo-deploy

`springboot-demo` 应用的 Kubernetes 部署清单（GitOps 仓库）。

- `k8s/app.yaml`：命名空间、MySQL 主从、Redis、后端、前端全部资源
- 镜像 tag 由 Jenkins 构建成功后自动写回（`harbor.local/demo/backend:<BUILD>` / `frontend:<BUILD>`）
- Argo CD 监听本仓库 `k8s` 目录，自动同步到集群 `demo` 命名空间
