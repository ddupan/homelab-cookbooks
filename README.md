# homelab-cookbooks

ddupan.top homelab 节点配置的 Cinc（Chef 的社区构建）cookbook。

本仓库只放**代码**：custom resource、recipe 与测试。哪个节点运行哪个 policy、节点属性和
policy lock 属于部署声明，放在 homelab-infra 的 `infrastructure/chef/`，按本仓库的 git tag 引用。

## 边界

- Chef 负责**节点**：包、系统配置、systemd，以及只有节点自己才能可靠收敛的东西。
- API 层配置不在这里：Ayatori（如 LoadBalancer 的 dataplaneapi/GoBGP 运行时配置）与
  Terraform 各自负责。被 API 改写的文件（如 dataplaneapi 管理的 HAProxy 配置）cookbook
  不得渲染。
- 节点发现以 DNS 为准（`lab.ddupan.top`），不用 Chef search；不部署 Cinc Server。

## 约定

- 每个通用配置项是一个 custom resource，用 ChefSpec 覆盖其分支与约束。
- 尽量用 `load_current_value` 或内置 resource 组合；不得不用 `execute` 时写 guard 并注释
  原因，否则 why-run 只能猜。
- **幂等是验收标准**：Kitchen 对每个平台收敛两次，`enforce_idempotency` 要求第二次
  0 个更新。

## 测试

本机不需要安装 Ruby，用 Cinc Workstation 镜像：

```bash
cd cookbooks/homelab_base
docker run --rm --network host -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:/cb" -w /cb docker.io/cincproject/workstation:26.3.0 \
  bash -lc 'cookstyle . && cinc install && cinc exec rspec && kitchen test --destroy=always'
```

需要 `--network host`：默认 bridge 上的容器连不到 dokken 网络，rsync 会超时。

## Cookbooks

| cookbook | 内容 |
|---|---|
| `homelab_base` | 内部 CA 信任、OpenBao SSH user CA 信任、node_exporter（容器内关闭宿主硬件类 collector）、漂移检查 timer 与运行报告、SPIRE agent（x509pop，lego ACME 节点证书） |
