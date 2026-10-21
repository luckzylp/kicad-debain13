# 发布流程

## 1. 版本号规则

```text
<上游版本>+dfsg-<官方 Debian 修订>+trixie<下游修订>
    10.0.7      +dfsg-          1          +trixie1
```

| 概念 | 当前值 | 说明 |
| --- | --- | --- |
| 上游稳定版 | `10.0.7` | 只接受正式稳定版 |
| 官方 Debian 源码包 | `10.0.7+dfsg-1` | sid 的打包基线 |
| 下游 Debian 版本 | `10.0.7+dfsg-1+trixie1` | 本仓库产出的版本 |
| Git 标签 | `v10.0.7` | 必须与清单中的 `RELEASE_TAG` 完全一致 |
| Release 标题 | `KiCad 10.0.7 for Debian 13 (amd64)` | 由清单生成 |

`+trixie1` 只表示下游修订，不表示“已经在 Trixie 上验证成功”。验证由构建门禁完成。

排序关系：

```text
10.0.7+dfsg-1 < 10.0.7+dfsg-1+trixie1 < 10.0.7+dfsg-2
```

因此 Debian 官方后续的 `-2` 会高于本仓库的 `+trixie1`，这是预期行为：本仓库不
冒充官方版本，也不阻止用户以后切换到官方包。

## 2. 发布前唯一事实来源

以下文件必须同步：

1. `packaging/versions.env`
   - `UPSTREAM_VERSION`
   - `DEBIAN_BASE_VERSION`
   - `DFSG_UPSTREAM_VERSION`
   - `DEBIAN_BASE_REVISION`
   - `DOWNSTREAM_REVISION`
   - `RELEASE_TAG`
   - `SOURCE_DSC` / `SOURCE_ORIG` / `SOURCE_ORIG_DOC` / `SOURCE_DEBIAN_TAR`
2. `packaging/sources.sha256`：四个官方文件的 SHA-256
3. `debian/changelog`：顶部条目必须是
   `kicad (<DEB_VERSION>) trixie; urgency=medium`
4. `packaging/allowed-packaging-diff.txt`：只允许 `debian/changelog`，除非确实新增
   了下游 patch

`scripts/validate-manifest.sh` 会检查 1–4 的一致性；`release.yml` 在构建前和发布
前各跑一次标签校验。

## 3. 升级到新上游版本

以 `10.0.8` 为例：

```bash
# 1. 查 Debian 源码包版本和校验和
#    https://packages.debian.org/sid/kicad
#    https://sources.debian.org/src/kicad/

# 2. 更新 packaging/versions.env：
#    UPSTREAM_VERSION=10.0.8
#    DEBIAN_BASE_VERSION=10.0.8+dfsg-1
#    DFSG_UPSTREAM_VERSION=10.0.8+dfsg
#    DOWNSTREAM_REVISION=1+trixie1
#    RELEASE_TAG=v10.0.8
#    SOURCE_DSC=...
#    SOURCE_ORIG=...
#    SOURCE_ORIG_DOC=...
#    SOURCE_DEBIAN_TAR=...

# 3. 重新生成 packaging/sources.sha256（从官方 .dsc 复制 Checksums-Sha256）

# 4. 导入新的官方 debian/：
#    下载新的 .debian.tar.xz，解包后替换 debian/，
#    再手工加回下游 changelog 条目。

# 5. 更新 changelog 顶部版本，递增下游修订

# 6. 跑完整门禁
make source provenance deps-check
sudo make deps
make build test audit checksums
make smoke   # 一次性容器/VM
```

不要只改 Git 标签。`validate-release-tag.sh` 会拒绝 `v10.0.8` 指向 10.0.7 源码的
情况。

### 仅重新打包（上游不变）

如果只修改了 `debian/`（例如增加 Trixie 补丁）：

1. `DOWNSTREAM_REVISION` 从 `1+trixie1` 改为 `1+trixie2`；
2. `debian/changelog` 增加对应条目；
3. `RELEASE_TAG` 改为新的唯一标签，例如 `v10.0.7-trixie2`；
4. 重新构建、测试、发布。

已有标签和 Release 资产不可覆盖。不要删除旧 Release 来“重发”同一个版本。

## 4. 发布门禁

正式标签只有满足以下全部条件才允许发布：

- [ ] `validate-manifest.sh` 通过
- [ ] `verify-packaging-provenance.sh` 通过
- [ ] `check-build-deps.sh` 在 Debian 13 上通过
- [ ] `dpkg-buildpackage` 退出码为 0
- [ ] 主包存在，版本为 `DEB_VERSION`，架构为 `amd64`
- [ ] `test-package.sh` 通过（文件布局、setuid、世界可写、依赖字段）
- [ ] `lintian --fail-on error` 通过；warning 已人工审查
- [ ] 干净 Debian 13 容器安装成功
- [ ] `kicad-cli version` 输出包含 `10.0.7`
- [ ] `import pcbnew` 成功
- [ ] 桌面文件通过 `desktop-file-validate`
- [ ] 卸载后无残留、`dpkg --audit` 为空
- [ ] `SHA256SUMS` 覆盖所有发布资产并重新验证
- [ ] `release` Environment 已配置人工审批（建议）

任何一项失败都不创建 Release。不要用“先发布再修”的方式绕过。

## 5. 标签与分支保护

建议在 GitHub 仓库设置中：

1. **Environments → release**
   - Required reviewers：至少 1 名维护者；
   - Deployment branches and tags：仅允许受保护的 `v*` 标签。
2. **Rules → Tags**
   - 限制 `v*` 标签的创建/删除/强制推送给维护者。
3. **Actions**
   - 默认 `GITHUB_TOKEN` 只读；
   - 仅 `release` job 提升为 `contents: write`；
   - 禁止 `pull_request_target`（CI 中有检查）。
4. **Self-hosted runner**
   - 只接受本仓库的 tag/manual workflow；
   - 不把 runner 开放给 fork PR；
   - 定期重建或使用一次性 VM。

## 6. 不签名发布

本仓库的 Release **不做 GPG 签名**。因此：

- 不需要 `RELEASE_GPG_PRIVATE_KEY`；
- 不需要 `RELEASE_GPG_PASSPHRASE`；
- 不需要 `RELEASE_KEY_FINGERPRINT`；
- Release 资产中不包含 `SHA256SUMS.asc` 或 `release-key.asc`。

发布 job 仍然会：

1. 下载经过构建和 smoke test 的同一批 artifact；
2. 附加 smoke test 报告；
3. 生成 Release notes；
4. 重新生成 `SHA256SUMS`，覆盖 `.deb`、`build-info.json`、Release notes 和报告；
5. 用 `sha256sum -c` 验证；
6. 通过 `gh release create` 发布。

`SHA256SUMS` 只能发现下载损坏或意外修改，**不能证明发布者身份**。如果用户需要确认
来源真实性，应通过独立可信渠道获取校验和，或自行构建。

### 6.1 为什么保留源码签名校验

Release 不签名，但 `fetch-source.sh` 仍然验证 Debian 官方 `.dsc` 的开发者签名。
这是为了确认构建输入来自 Debian 官方源码包，与“是否给最终 `.deb` 签名”是两件事。
不要因为关闭 Release 签名就跳过 `.dsc` 校验。

### 6.2 如果以后想恢复签名

需要重新引入签名脚本、工作流步骤和文档，并配置专用密钥。当前版本明确不提供该
功能，避免出现“看起来签名了、实际没有”的状态。

## 7. 发布操作

1. 确认 `main` 上的 CI 全绿。
2. 确认 `packaging/versions.env`、`debian/changelog`、`sources.sha256` 已提交。
3. 手动运行一次 `Build Debian package`（`workflow_dispatch`），选择
   `github-hosted` 或 `self-hosted-vm`，下载 artifact 做最终检查；这一步不创建
   Release。
4. 创建并推送标签：

   ```bash
   git tag -a v10.0.7 -m "KiCad 10.0.7 for Debian 13 (trixie1)"
   git push origin v10.0.7
   ```

5. `Release` workflow 依次执行：标签校验 → 构建 → 干净容器安装测试 → 人工审批 →
   重新生成并验证 `SHA256SUMS` → `gh release create`。
6. 在 GitHub Release 页面再次核对：
   - 版本、架构、标签；
   - `.deb`、`SHA256SUMS`、`build-info.json`；
   - Release notes 中的安装/验证命令。
7. 在一台干净的 Debian 13 机器上按 Release notes 完整验证一次。

## 8. 用户验证

```bash
sha256sum -c SHA256SUMS
sudo apt install ./kicad_10.0.7+dfsg-1+trixie1_amd64.deb
kicad-cli version
```

校验和只能发现损坏或意外修改，不能证明发布者身份。对来源真实性有要求时，请通过
独立可信渠道获取 `SHA256SUMS`，或自行从源码构建。

## 9. 回滚与撤回

- **不要删除或覆盖已发布资产**；GitHub Release 资产是不可变历史的一部分。
- 如果包有严重问题：
  1. 将 Release 标记为 pre-release 或在说明顶部加显著警告；
  2. 发布新的 `+trixieN` 修订修复；
  3. 必要时在仓库发布 Security Advisory；
  4. 不建议直接删除标签，除非仓库/账号被入侵等极端情况，并记录原因。
- 用户侧回滚：`sudo apt install ./kicad_<older-version>_amd64.deb`，或卸载后安装
  Debian 官方 9.0.x。

## 10. Release 资产清单

| 文件 | 说明 |
| --- | --- |
| `kicad_..._amd64.deb` | 主程序包 |
| `kicad_..._amd64.buildinfo` | 构建环境/校验和 |
| `kicad_..._amd64.changes` | Debian 二进制上传描述 |
| `SHA256SUMS` | 所有资产的校验和 |
| `build-info.json` | 源码摘要、构建 runner、产物哈希 |
| `RELEASE-NOTES.md` | 安装/验证/限制说明 |
| `reports/*` | 构建依赖、Lintian、环境、源码 provenance |

`.deb` 的 `Depends` 由 `dpkg-shlibdeps` 生成；不要手工编辑。安装测试在干净
Debian 13 容器中进行，构建容器中的已有依赖不会掩盖缺失的运行时依赖。
