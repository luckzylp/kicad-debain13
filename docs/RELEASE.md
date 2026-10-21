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
- [ ] `SHA256SUMS` 覆盖所有发布资产
- [ ] `SHA256SUMS.asc` 由已登记指纹的密钥签名并可验证
- [ ] `release` Environment 已人工审批

任何一项失败都不创建 Release。不要用“先发布再修”的方式绕过。

## 5. 标签与分支保护

建议在 GitHub 仓库设置中：

1. **Environments → release**
   - Required reviewers：至少 1 名维护者；
   - Deployment branches and tags：仅允许受保护的 `v*` 标签；
   - 不要把签名私钥放到普通 Actions secret，放在 Environment secret。
2. **Rules → Tags**
   - 限制 `v*` 标签的创建/删除/强制推送给维护者；
   - 如可能，要求签名标签。
3. **Actions**
   - 默认 `GITHUB_TOKEN` 只读；
   - 仅 `release` job 提升为 `contents: write`；
   - 禁止 `pull_request_target`（CI 中有检查）。
4. **Self-hosted runner**
   - 只接受本仓库的 tag/manual workflow；
   - 不把 runner 开放给 fork PR；
   - 定期重建或使用一次性 VM。

## 6. 签名密钥

### 6.1 生成专用密钥

不要复用个人日常 GPG 密钥。建议使用离线/受控环境生成，密钥只用于发布：

```bash
gpg --quick-generate-key \
  "KiCad Debian 13 Release <kicad-debian13@users.noreply.github.com>" \
  rsa4096 sign 2y

FPR="$(gpg --with-colons --list-secret-keys \
  | awk -F: '$1=="fpr" {print $10; exit}')"
echo "$FPR"

gpg --armor --export "$FPR" > release-key.asc
gpg --armor --export-secret-keys "$FPR" > release-key.private.asc

# 立即把私钥放入 GitHub Environment secret，然后从磁盘安全删除
gh secret set RELEASE_GPG_PRIVATE_KEY --env release < release-key.private.asc
gh variable set RELEASE_KEY_FINGERPRINT --body "$FPR"

shred -u release-key.private.asc
```

- `RELEASE_GPG_PRIVATE_KEY`：ASCII-armored 私钥，放在 **Environment** `release`
  的 secret 中。
- `RELEASE_KEY_FINGERPRINT`：完整 40 位指纹，放在 repository variable。
- `RELEASE_GPG_PASSPHRASE`：如私钥有口令，放在 Environment secret；无口令则不设置。
- `release-key.asc` 可以提交到仓库，也可以只随 Release 发布。当前流水线在发布时
  从私钥导出公钥，并把它加入 `SHA256SUMS`。

`sign-release.sh` 会：

1. 在临时 `GNUPGHOME` 中导入私钥；
2. 读取实际指纹并与 `RELEASE_KEY_FINGERPRINT` 比对；
3. 导出公钥到 `dist/release-key.asc`；
4. 重新生成 `SHA256SUMS`（包含公钥、Release notes、报告）；
5. 签名并立即验证；
6. 清理临时密钥目录。

指纹不匹配、私钥为空、签名失败都会阻止发布。

### 6.2 轮换/吊销

1. 生成新密钥，更新 Environment secret 与 `RELEASE_KEY_FINGERPRINT`；
2. 在 README/Release 说明中公布新旧指纹和轮换日期；
3. 旧密钥如泄露，立即吊销并在仓库发布安全公告；
4. 已发布的旧资产不会因为轮换而自动可信，用户仍应按发布时的指纹验证。

## 7. 发布操作

1. 确认 `main` 上的 CI 全绿。
2. 确认 `packaging/versions.env`、`debian/changelog`、`sources.sha256` 已提交。
3. 手动运行一次 `Build Debian package`（`workflow_dispatch`），选择
   `github-hosted` 或 `self-hosted-vm`，下载 artifact 做最终检查；这一步不创建
   Release。
4. 创建并推送标签：

   ```bash
   git tag -s v10.0.7 -m "KiCad 10.0.7 for Debian 13 (trixie1)"
   git push origin v10.0.7
   ```

5. `Release` workflow 依次执行：标签校验 → 构建 → 干净容器安装测试 → 人工审批 →
   签名 → `gh release create`。
6. 在 GitHub Release 页面再次核对：
   - 版本、架构、标签；
   - `.deb`、`SHA256SUMS`、`SHA256SUMS.asc`、`release-key.asc`、`build-info.json`；
   - Release notes 中的安装/验证命令；
   - 公钥指纹。
7. 在一台干净的 Debian 13 机器上按 Release notes 完整验证一次。

## 8. 用户验证

```bash
gpg --import release-key.asc
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
sudo apt install ./kicad_10.0.7+dfsg-1+trixie1_amd64.deb
kicad-cli version
```

指纹必须从独立渠道（项目 README、维护者公告）核对。签名文件与 `.deb` 一起下载
不构成信任。

## 9. 回滚与撤回

- **不要删除或覆盖已发布资产**；GitHub Release 资产是不可变历史的一部分。
- 如果包有严重问题：
  1. 将 Release 标记为 pre-release 或在说明顶部加显著警告；
  2. 发布新的 `+trixieN` 修订修复；
  3. 必要时在仓库发布 Security Advisory；
  4. 不建议直接删除标签，除非密钥泄露等极端情况，并记录原因。
- 用户侧回滚：`sudo apt install ./kicad_<older-version>_amd64.deb`，或卸载后安装
  Debian 官方 9.0.x。

## 10. Release 资产清单

| 文件 | 说明 |
| --- | --- |
| `kicad_..._amd64.deb` | 主程序包 |
| `kicad_..._amd64.buildinfo` | 构建环境/校验和 |
| `kicad_..._amd64.changes` | Debian 二进制上传描述 |
| `SHA256SUMS` | 所有资产的校验和 |
| `SHA256SUMS.asc` | 对校验和文件的分离签名 |
| `release-key.asc` | 发布公钥 |
| `build-info.json` | 源码摘要、构建 runner、产物哈希 |
| `RELEASE-NOTES.md` | 安装/验证/限制说明 |
| `reports/*` | 构建依赖、Lintian、环境、源码 provenance |

`.deb` 的 `Depends` 由 `dpkg-shlibdeps` 生成；不要手工编辑。安装测试在干净
Debian 13 容器中进行，构建容器中的已有依赖不会掩盖缺失的运行时依赖。
