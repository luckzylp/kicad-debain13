# 构建指南

## 1. 目标与约束

本仓库只构建：

- Debian 13 (trixie)
- amd64
- 上游 KiCad 正式稳定版（当前 `10.0.7`）
- 官方 Debian 上游源码包（当前 `10.0.7+dfsg-1`）
- 默认只产出 `kicad` 二进制包（`dpkg-buildpackage -B`）

不在范围内：arm64/i386、nightly/rc/beta、Ubuntu、Debian testing/unstable、
KiCad 官方 PPA 的库包、自动更新器。

## 2. 构建环境

### 2.1 资源

| 资源 | 最低 | 建议 |
| --- | --- | --- |
| 磁盘 | 7 GiB 硬下限（`scope=arch`，很紧） | 20 GiB（`scope=full` 30 GiB） |
| 内存 | 8 GiB | 16 GiB |
| CPU | 2 核 | 4 核以上 |
| 网络 | 可访问 `deb.debian.org` 与 GitHub | 同左 |

`scope=full` 会额外构建演示工程和翻译文档，需要约 30 GiB 磁盘，并显著延长
构建时间。脚本在 `scope=arch` 时硬性要求 7 GiB、低于 20 GiB 会警告；`scope=full`
硬性要求 25 GiB。GitHub 托管标准 runner 只有约 14 GiB 可用空间，因此完整的
KiCad 构建可能偏紧；需要稳定发布时请使用自建 Debian 13 VM。

### 2.2 为什么必须是 Debian 13

KiCad 的 Debian 包链接 Trixie 的 ABI：glibc、wxWidgets 3.2、Boost 1.83、
OpenCASCADE 7.8、Python 3.13 等。在 Ubuntu 或 sid 上编译后再拿到 Trixie 上
运行，可能因为符号版本、依赖版本或 Python ABI 不匹配而失败。构建环境必须是
Debian 13 用户空间。

### 2.3 两种运行方式

#### A. GitHub 托管 runner + Debian 13 容器（默认）

```yaml
runs-on: ubuntu-24.04
container:
  image: debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308
```

GitHub 托管 runner 本身是 Ubuntu 虚拟机；`container` 让所有构建步骤在 Debian 13
用户空间中执行。内核仍是 runner 的 Ubuntu 内核，但 Debian 包构建不依赖内核版本。
容器镜像使用 digest 固定，避免 `debian:13` 标签漂移。

#### B. 自建 Debian 13 虚拟机/物理机

```yaml
runs-on: [self-hosted, debian-13, kicad-builder]
```

这是字面意义上的 Debian 13 虚拟机。runner 需要：

- Debian 13 amd64；
- 标签 `debian-13` 和 `kicad-builder`；
- runner 用户可无密码 `sudo apt-get`（脚本用 `apt_get` 包装 apt 并在需要时自动调用 sudo）；
- 专用机器，不执行不可信 PR 的代码；
- 至少 20–30 GiB 空闲磁盘，定期清理 workspace。

完整步骤见 [SELF-HOSTED-VM.md](SELF-HOSTED-VM.md)。

#### 为什么不在 GitHub 托管 runner 里启动 QEMU 全虚拟机

标准 GitHub 托管 runner 不暴露 `/dev/kvm`。KiCad 是大型 C++ 工程，纯 TCG
软件模拟编译会远超 6 小时 job 上限，也会让缓存和磁盘不可控。因此：

- 需要“Debian 13 用户空间”时，用容器；
- 需要“真正的 Debian 13 虚拟机”时，用自建 runner；
- 不在 CI 中做不可行的嵌套全虚拟化。

## 3. 本地构建（Debian 13）

```bash
# 0. 克隆仓库
git clone https://github.com/OWNER/REPO.git kicad-debian13
cd kicad-debian13

# 1. 安装打包工具（root/sudo）
sudo ./scripts/install-build-tools.sh

# 2. 下载并认证官方源码（约 260 MiB，首次会慢）
./scripts/fetch-source.sh

# 3. 证明 vendored debian/ 就是官方打包，只多了 changelog 条目
./scripts/verify-packaging-provenance.sh

# 4. 只解析、不安装：确认 Trixie 能满足 Build-Depends
./scripts/check-build-deps.sh

# 5. 安装 Build-Depends（root/sudo），然后编译
sudo ./scripts/install-build-deps.sh
./scripts/build-deb.sh --scope arch

# 6. 静态检查、Lintian、校验和
./scripts/test-package.sh
./scripts/audit-package.sh
./scripts/make-checksums.sh

# 7. 可选：在一次性容器/VM 中安装、运行、卸载
sudo ./tests/package-smoke-test.sh
```

产物在 `dist/`，中间源码树在 `build/source/`，日志和报告在 `build/logs/`、
`build/reports/`。

### 3.1 使用容器

```bash
docker run --rm -it \
  -v "$PWD:/work" \
  -w /work \
  debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308 \
  bash
```

容器内是 root，可以直接运行：

```bash
./scripts/install-build-tools.sh
./scripts/fetch-source.sh
./scripts/check-build-deps.sh
./scripts/install-build-deps.sh
./scripts/build-deb.sh --scope arch
./scripts/test-package.sh
./scripts/audit-package.sh
./scripts/make-checksums.sh
```

退出后如果 `build/`、`dist/` 变成 root 所有：

```bash
sudo chown -R "$(id -u):$(id -g)" build dist .cache
```

## 4. 脚本职责

| 脚本 | 作用 | 需要 root |
| --- | --- | --- |
| `install-build-tools.sh` | 安装 `dpkg-dev`、`devscripts`、`lintian`、`quilt`、GPG、curl 等 | 是 |
| `fetch-source.sh` | 下载 `.dsc`/orig/debian tar，校验 SHA-256 与 Debian 签名，解包并叠加 `debian/` | 否 |
| `verify-packaging-provenance.sh` | 将 `debian/` 与官方 `.debian.tar.xz` 逐文件比对 | 否 |
| `check-build-deps.sh` | `apt-get -s build-dep`，只从 Trixie 解析依赖 | 否 |
| `install-build-deps.sh` | `apt-get build-dep -y` + `dpkg-checkbuilddeps` | 是 |
| `build-deb.sh` | `dpkg-buildpackage`、收集 `.deb`、版本/架构断言 | 否 |
| `test-package.sh` | `dpkg-deb` 结构、文件布局、setuid、世界可写检查 | 否 |
| `audit-package.sh` | Lintian，错误阻断；警告记录待审 | 否 |
| `make-checksums.sh` | 对 `dist/` 中所有发布资产生成 `SHA256SUMS` | 否 |
| `make-build-info.py` | 生成 `build-info.json` | 否 |
| `make-release-notes.sh` | 生成 Release 说明 | 否 |
| `sign-release.sh` | 校验私钥指纹、导出公钥、重算校验和、签名 | 否 |
| `validate-manifest.sh` | 版本/发行版/tag/校验和清单一致性 | 否 |
| `validate-release-tag.sh` | 标签必须与 `RELEASE_TAG` 完全一致 | 否 |
| `prepare-workspace.sh` | 清理旧产物、检查磁盘/内存/环境 | 否 |

## 5. 源码认证流程

`fetch-source.sh` 不添加 sid apt 源，也不依赖 sid 的 Packages/Sources 索引。它直接
从 Debian pool 下载四个固定文件：

```text
kicad_10.0.7+dfsg-1.dsc
kicad_10.0.7+dfsg.orig.tar.xz
kicad_10.0.7+dfsg.orig-doc.tar.xz
kicad_10.0.7+dfsg-1.debian.tar.xz
```

校验步骤：

1. 每个文件的 SHA-256 与 `packaging/sources.sha256` 一致；
2. `.dsc` 中的 `Checksums-Sha256` 表与同一份清单一致；
3. `gpgv --keyring /usr/share/keyrings/debian-keyring.*` 验证 `.dsc` 的 Debian
   开发者签名；
4. `dscverify` 再次校验 `.dsc` 及其引用的所有 tarball；
5. `dpkg-source -x` 解包，`quilt pop -a` 回到未打补丁状态；
6. 用仓库的 `debian/` 替换官方 `debian/`；
7. `dpkg-source --before-build` 应用仓库的 patch 队列；
8. 断言 `debian/changelog` 的 Source、Version、Distribution 与清单一致。

没有 `debian-keyring` 时脚本会失败，并提示安装。**不要**为了“让 CI 变绿”而跳过
签名校验。

## 6. 打包配置来源

`debian/` 来自 Debian sid 的官方源码包，不是手写的最小 control。当前唯一允许的
差异是 `debian/changelog` 顶部新增的下游条目：

```text
kicad (10.0.7+dfsg-1+trixie1) trixie; urgency=medium
```

`verify-packaging-provenance.sh` 会逐文件比较类型、权限、符号链接目标和 SHA-256。
新增下游 patch 时，必须：

1. 把 patch 放入 `debian/patches/` 并加入 `series`；
2. 在 `packaging/allowed-packaging-diff.txt` 增加相应路径；
3. 在 `debian/changelog` 记录原因；
4. 在 PR 中说明为什么不能通过升级依赖或上游修复解决。

官方 changelog 必须仍是当前 changelog 的精确后缀；不能删除或改写 Debian 的历史
条目。

## 7. 依赖策略

- 只使用 Debian 13 的二进制仓库。
- 不添加 sid 二进制仓库，不安装 sid 的 `.deb` 来“凑”依赖。
- `apt-get build-dep` 失败时，按以下顺序评估：
  1. 该版本约束是否真的必要？能否用上游兼容补丁降低要求？
  2. 是否可以把依赖 backport 到 Trixie 并单独维护？
  3. 是否应暂缓该 KiCad 版本的 Trixie 发布？
- 不删除 `Build-Depends`、不关闭 `dpkg-shlibdeps`、不使用
  `--force-depends` 来绕过 ABI 问题。

当前 `10.0.7+dfsg-1` 的 `Build-Depends` 在 Debian 13 上可以完整解析；这只是
**依赖可满足**，不等于编译一定成功。编译失败仍然阻断发布。

## 8. Trixie 适配流程（构建失败时）

1. 在本地或 CI 中复现，保留 `build/logs/build.log` 和 `build/reports/`。
2. 判断失败类型：
   - 依赖版本不满足：回到第 7 节；
   - 编译/API 不兼容：在 `debian/patches/` 增加最小补丁；
   - 测试失败：判断是环境问题还是真实回归；
   - 磁盘/内存不足：增大 runner 或降低并行度（`make build JOBS=2`）。
3. 修改后更新 `debian/changelog`，递增 `+trixieN`。
4. 如果新增/修改了打包文件，更新 `packaging/allowed-packaging-diff.txt`。
5. 重新跑完整的 `check-build-deps → build → test → audit → smoke`。
6. 在 PR 中附上失败日志、根因和补丁理由。

## 9. 构建范围

`scope=arch`（默认）：

```bash
dpkg-buildpackage -B -uc -us -j"$(nproc)"
```

只构建 `Architecture: any` 的 `kicad` 包。`debian/rules` 仍会配置文档目录，因此
`Build-Depends-Indep` 也会被安装，但不会编译全部翻译文档。

`scope=full`：

```bash
dpkg-buildpackage -b -uc -us -j"$(nproc)"
```

额外构建 `kicad-demos`、`kicad-libraries` 元包和各语言 `kicad-doc-*`。体积大、
耗时长，且 `kicad-libraries` 在 Trixie 上仍依赖不存在的 10.0.x 库包，不建议作为
默认发布产物。

## 10. 可复现性

脚本设置：

```bash
SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -S Date)
DEB_BUILD_OPTIONS="parallel=N reproducible=+fixfilepath noautodbgsym"
TZ=UTC LC_ALL=C.UTF-8
umask 022
```

这消除了大部分时间戳和路径差异，但本仓库 **尚未** 做双构建逐字节比对。要验证
可复现性，可在同一镜像中连续构建两次，比较 `.deb` 的 SHA-256；如果不同，使用
`diffoscope` 定位。不要把“设置了 SOURCE_DATE_EPOCH”等同于“已经可复现”。

## 11. 常见问题

### `dscverify: no keyring`

安装 `debian-keyring`：

```bash
sudo apt-get install debian-keyring
```

脚本会自动寻找 `/usr/share/keyrings/debian-keyring.gpg` 或
`debian-keyring.pgp`。也可以设置 `DEBIAN_KEYRING` 指向其他 keyring。

### `dpkg-source -x` 报 “unpack target exists”

`build/source/` 已存在。运行 `./scripts/prepare-workspace.sh` 或删除
`build/source` 后重试。不要删除仓库根目录。

### `apt-get build-dep` 报无法满足

这是设计上的失败。记录完整输出，按第 7 节评估；不要添加 sid 源。

### 编译被 OOM kill

降低并行度：

```bash
JOBS=2 ./scripts/build-deb.sh --scope arch
```

或增加 runner 内存。KiCad 的链接阶段内存占用较高。

### 磁盘不足

`scope=arch` 硬下限 7 GiB（建议 20 GiB），`scope=full` 硬下限 25 GiB（建议
30 GiB）。清理旧的
`build/`、`dist/` 和容器镜像；`.cache/downloads` 只有约 260 MiB，可以保留以加速
重跑。

## 12. 相关文档

- [RELEASE.md](RELEASE.md)：版本、标签、签名、发布清单
- [SECURITY.md](SECURITY.md)：威胁模型与供应链安全
- [SELF-HOSTED-VM.md](SELF-HOSTED-VM.md)：自建 Debian 13 runner
