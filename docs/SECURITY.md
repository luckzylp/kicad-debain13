# 安全模型

## 1. 范围

本仓库的信任目标是：用户下载到的 `.deb` 确实由本仓库的发布密钥签名，且其内容
来自 `packaging/versions.env` 指定的 Debian 官方 KiCad 源码包，没有在构建链中
被替换。

本仓库 **不** 声称：

- 是 Debian 官方项目；
- 对上游 KiCad 源码本身做安全审计；
- 签名密钥绝对不可能泄露；
- 产物已经过独立可复现构建验证；
- 能防御已经取得构建 runner root 权限的攻击者。

## 2. 信任边界

```text
Debian archive (.dsc + tarballs)
        │  签名 + SHA-256 + dscverify
        ▼
packaging/sources.sha256 (committed)
        │
        ▼
Debian 13 build environment
        │  dpkg-buildpackage, Trixie binary deps only
        ▼
dist/*.deb + reports + build-info.json
        │  SHA256SUMS
        ▼
release key (Environment secret) ──► SHA256SUMS.asc
        │
        ▼
GitHub Release
```

### 2.1 源码

- `.dsc` 由 Debian 开发者签名；CI 使用 `debian-keyring` 验证。
- 四个源码文件的 SHA-256 固定在 `packaging/sources.sha256`，并与 `.dsc` 内的
  `Checksums-Sha256` 交叉比对。
- `dscverify` 再次校验所有引用文件。
- 源码 tarball 解包后，`debian/` 只允许 changelog 差异；官方 changelog 必须作为
  精确后缀保留。
- 不添加 sid apt 源；不会因为 `apt-get build-dep` 而隐式拉入 sid 二进制。

### 2.2 构建

- 构建只在 Debian 13 用户空间进行（容器或自建 VM）。
- 依赖只从 Debian 13 解析；不满足时失败，而不是降级/忽略依赖。
- `debian/rules`、`debian/patches` 来自官方包；任何下游 patch 都必须在 Git 中
  审查并写入 `packaging/allowed-packaging-diff.txt`。
- `dpkg-buildpackage` 不签名源码包；发布签名只覆盖校验和文件。
- 构建日志、Lintian、依赖解析和源码 provenance 作为 Release 资产公开。

### 2.3 发布

- 标签必须与 `RELEASE_TAG` 完全一致；`v*` 通配符不会让旧源码以新版本发布。
- `release` GitHub Environment 应要求人工审批，并限制可部署的标签。
- 私钥放在 Environment secret；仓库变量只保存公钥指纹。
- `sign-release.sh` 在临时 `GNUPGHOME` 中导入私钥，比对指纹，签名后立即验证并
  清理。
- `SHA256SUMS` 覆盖 `.deb`、`.buildinfo`、`.changes`、`build-info.json`、
  Release notes、公钥和报告；`SHA256SUMS.asc` 是分离签名。
- 发布 job 只使用本次构建上传的 artifact，不重新构建，避免“测试的和发布的不
  是同一批文件”。

## 3. 威胁与缓解

| 威胁 | 缓解 |
| --- | --- |
| Debian 源码包被替换 | `.dsc` 开发者签名 + 固定 SHA-256 + `dscverify` |
| 下载镜像被劫持 | HTTPS + 固定校验和 + 签名；可切换 `DEBIAN_MIRROR` |
| 构建时混入 sid 二进制 | 不配置 sid 源；依赖解析失败即停止 |
| 打包配置被悄悄修改 | 与官方 `.debian.tar.xz` 逐文件、逐权限比对；allowlist 审查 |
| 构建环境被污染 | 每次干净容器/专用 VM；`prepare-workspace.sh` 清理旧产物 |
| 标签指向旧源码 | 标签必须精确等于 `RELEASE_TAG`；`validate-release-tag.sh` 双重执行 |
| 发布密钥被盗 | 专用密钥、Environment 审批、指纹固定、临时 GNUPGHOME、轮换流程 |
| 构建 artifact 被替换 | 发布 job 下载同一 run 的 artifact；校验和 + 签名 |
| 供应链 action 被替换 | GitHub 官方 action 按 commit SHA 固定；Dependabot 跟踪 |
| 自建 runner 被不可信代码使用 | 只允许 tag/manual；禁止 fork PR；专用 VM；最小 sudo |

## 4. 自建 runner 的风险

自建 Debian 13 VM 能提供真正的虚拟机隔离，但也把宿主暴露给 workflow 代码。
务必：

- 只让本仓库的受信任维护者触发 workflow；
- 不给 fork PR 使用该 runner；
- runner 用户只对 `apt-get`/`dpkg` 有最小 sudo 权限；
- 定期重建 VM，或使用一次性快照；
- 不在 runner 上保存发布私钥（私钥只通过 GitHub Environment secret 注入发布
  job，而发布 job 默认跑在 GitHub 托管 runner 上）；
- 限制 runner 的出站网络，只允许 Debian/GitHub 必要域名（如条件允许）。

发布 job 默认使用 `ubuntu-24.04`，不跑在自建 VM 上；即使构建在 VM 上完成，
签名也在 GitHub 托管的受保护环境中进行。

## 5. 签名能证明什么

`gpg --verify SHA256SUMS.asc SHA256SUMS` 成功只说明：

- 该签名由对应私钥生成；
- `SHA256SUMS` 自签名后未被修改；
- 下载文件与 `SHA256SUMS` 中的哈希一致。

它 **不** 自动证明：

- 私钥持有人可信；
- 构建过程没有被攻破；
- 源码没有后门；
- 该包适合你的系统。

用户必须通过独立渠道核对密钥指纹，并自行判断是否信任本项目。

## 6. 可复现性现状

当前只设置了 `SOURCE_DATE_EPOCH`、`reproducible=+fixfilepath`、固定 locale 和
`umask`，尚未做双构建逐字节比对。因此：

- 不能声称“可复现构建已验证”；
- `build-info.json` 记录源码摘要、runner、commit 和产物哈希，便于第三方比较；
- 欢迎提交独立复现结果；如发现差异，使用 `diffoscope` 定位。

## 7. 漏洞报告

请使用 GitHub 仓库的 **Security → Report a vulnerability**（Security Advisories）
私下报告。不要在公开 issue 中发布：

- 发布私钥、口令、token；
- 未修复的供应链漏洞细节；
- 可直接利用的构建/签名绕过方法。

维护者应在确认后：

1. 评估影响范围（哪些版本、哪些资产）；
2. 准备修复和新 `+trixieN` 版本；
3. 必要时吊销/轮换密钥；
4. 发布 Security Advisory，并在 Release notes 中说明。

## 8. 安全相关配置清单

- [ ] `release` Environment 需要人工审批
- [ ] `v*` 标签受保护，只有维护者可创建
- [ ] `RELEASE_KEY_FINGERPRINT` 已设置为完整 40 位指纹
- [ ] `RELEASE_GPG_PRIVATE_KEY` 只存在于 Environment secret
- [ ] `GITHUB_TOKEN` 默认只读
- [ ] 自建 runner 只对受信任 workflow 开放
- [ ] Dependabot 已启用（`.github/dependabot.yml`）
- [ ] 定期检查 Debian 源码包版本和安全公告
