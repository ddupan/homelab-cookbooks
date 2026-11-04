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
cb=homelab_base
docker run --rm --network host -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/cookbooks:/cookbooks" -w "/cookbooks/$cb" docker.io/cincproject/workstation:26.3.0 \
  bash -lc 'cookstyle . && cinc install && cinc exec rspec && kitchen test --destroy=always'
```

需要 `--network host`：默认 bridge 上的容器连不到 dokken 网络，rsync 会超时。
挂载整个 `cookbooks/`：Policyfile 会按路径引用同级 cookbook（homelab_loadbalancer 依赖 homelab_base）。

Docker Hub 对匿名拉取按出口 IP 限流，lab 共用一个出口。被限流时加
`-e DOKKEN_REGISTRY=nexus.lab.ddupan.top/oci-public`，Kitchen 的所有镜像都改走 Nexus 代理
（CI 一直这样做）。

## Cookbooks

| cookbook | 内容 |
|---|---|
| `homelab_base` | 内部 CA 信任、OpenBao SSH user CA 信任、node_exporter（容器内关闭宿主硬件类 collector）、漂移检查 timer 与运行报告、SPIRE agent（x509pop，lego ACME 节点证书） |
| `homelab_loadbalancer` | Ayatori LoadBalancer 主机：服务端证书（lego，Bao `pki/` ACME，节点地址 http-01）、HAProxy 3.4（Chef 只管 `base.cfg`，`haproxy.cfg` 归 dataplaneapi）、Data Plane API（仅 mTLS）、Ayatori LB agent（Ayatori release 附件，本机判断并宣告 VIP；专用用户，仅 `CAP_NET_ADMIN` 与 HAProxy socket；0.3.0 起取代并清除 gobgpd） |
| `homelab_ayatori` | Ayatori API-only 控制面：k0s controller-only（只开 namespace 与客户端证书签发相关控制器）、Flux/ESO/kube-state-metrics/ayatori-manager 的 podman quadlet、客户端证书（bootstrap token 首次签发并核对批准，client-credentials 自行续签，Ayatori ADR-0021）、k0s 备份与证书到期指标；`adopt` recipe 接管原 Ansible 部署的节点 |
| `homelab_data` | 共享数据服务节点（etcd-pve1/2）：维护指标（etcd 快照、证书到期、pgBackRest full 备份），发行版 node_exporter 第二实例只读 textfile、监听节点地址 :9109；`collect.py` 是唯一来源，laptop 的 Ansible play 按 tag 下载它 |
