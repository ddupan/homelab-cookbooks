# Changelog

## [0.5.0](https://github.com/ddupan/homelab-cookbooks/compare/homelab_ayatori-v0.4.0...homelab_ayatori-v0.5.0) (2026-11-25)


### 新功能

* **homelab_ayatori:** apiserver 接受 SPIFFE JWT-SVID ([c927cff](https://github.com/ddupan/homelab-cookbooks/commit/c927cffc51c2b51d6be89be1d412cd1d2840e299))
* **homelab_ayatori:** apiserver 接受 SPIFFE JWT-SVID ([38ef689](https://github.com/ddupan/homelab-cookbooks/commit/38ef689190e053adcabcbb54622c9f53516912df))
* **homelab_ayatori:** 部署 ayatori-api ([b589714](https://github.com/ddupan/homelab-cookbooks/commit/b589714c513bb906a9c91b6c40b86cb13957167f))
* **homelab_ayatori:** 部署 ayatori-api ([cffb40c](https://github.com/ddupan/homelab-cookbooks/commit/cffb40caf344ef20dc31d3256b432670e5e82d4d))


### 修复

* **homelab_ayatori:** ayatori-api 服务证书提前到 45 天重签 ([6052cd5](https://github.com/ddupan/homelab-cookbooks/commit/6052cd53f095d0b53c7087482e05864540986a80))
* **homelab_ayatori:** 首次开启 ayatori_api 时 why-run 不失败 ([17006e8](https://github.com/ddupan/homelab-cookbooks/commit/17006e81eaae75d3917e4d19925643f71e5d7d60))
* **homelab_ayatori:** 首次开启 ayatori_api 时 why-run 不失败 ([385893c](https://github.com/ddupan/homelab-cookbooks/commit/385893c6ba47ba44e3f5a4fc6774baa49439caff))

## [0.4.0](https://github.com/ddupan/homelab-cookbooks/compare/homelab_ayatori-v0.3.0...homelab_ayatori-v0.4.0) (2026-11-24)


### ⚠ BREAKING CHANGES

* **homelab_loadbalancer,homelab_compute,homelab_ayatori:** GitHub 上只有 v0.5.0 起的 release 附件，更早的 lb-agent 版本只在 Gitea。升级到这个 cookbook 版本时，policy 里的 agent version 要同时改到 0.5.0 或更新，或者显式传 url_base。

### 新功能

* **homelab_loadbalancer,homelab_compute,homelab_ayatori:** Ayatori 制品改从 GitHub 获取 ([8ae4e57](https://github.com/ddupan/homelab-cookbooks/commit/8ae4e57daca34424afb6843cb58bf85efcd8b781))


### 修复

* **homelab_ayatori:** systemd 正在自动重启的容器不再由 Chef 启动 ([c936250](https://github.com/ddupan/homelab-cookbooks/commit/c93625094655df85acec54c809c7f2a530d9990a))
* **homelab_ayatori:** 首次安装容器时不再在启动过程中 restart ([88927a3](https://github.com/ddupan/homelab-cookbooks/commit/88927a3d41bdbeb86531e5a8f92fe3c9ad9a7ef7))


### 依赖与维护

* metadata 的 source_url 改为 GitHub ([1e7d691](https://github.com/ddupan/homelab-cookbooks/commit/1e7d691a30c2758915230c6df15fffc5c86d0e40))
