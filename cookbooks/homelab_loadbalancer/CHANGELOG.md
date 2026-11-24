# homelab_loadbalancer 变更记录

## [0.6.0](https://github.com/ddupan/homelab-cookbooks/compare/homelab_loadbalancer-v0.5.1...homelab_loadbalancer-v0.6.0) (2026-11-24)


### ⚠ BREAKING CHANGES

* **homelab_loadbalancer,homelab_compute,homelab_ayatori:** GitHub 上只有 v0.5.0 起的 release 附件，更早的 lb-agent 版本只在 Gitea。升级到这个 cookbook 版本时，policy 里的 agent version 要同时改到 0.5.0 或更新，或者显式传 url_base。

### 新功能

* **homelab_loadbalancer,homelab_compute,homelab_ayatori:** Ayatori 制品改从 GitHub 获取 ([8ae4e57](https://github.com/ddupan/homelab-cookbooks/commit/8ae4e57daca34424afb6843cb58bf85efcd8b781))


### 依赖与维护

* metadata 的 source_url 改为 GitHub ([1e7d691](https://github.com/ddupan/homelab-cookbooks/commit/1e7d691a30c2758915230c6df15fffc5c86d0e40))

## 0.5.1 (2026-11-18)

### 修复

- fix(homelab_loadbalancer): haproxy 固定到精确版本，补丁版本可被跟踪 (eb54af6)
