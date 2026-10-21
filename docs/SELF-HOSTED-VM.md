# 自建 Debian 13 VM runner

本文件说明如何把一台 Debian 13 amd64 虚拟机注册为 GitHub Actions self-hosted
runner，并在 `build.yml` 中使用 `runner: self-hosted-vm`。

如果你只是偶尔构建，使用默认的 `github-hosted` 容器模式更简单；自建 VM 适合
需要真正 Debian 13 内核/虚拟机边界、或需要更多 CPU/磁盘的场景。

## 1. 规格与前提

| 项目 | 建议 |
| --- | --- |
| 系统 | Debian 13 (trixie) amd64，最小安装 |
| CPU | 8 核 |
| 内存 | 16 GiB |
| 磁盘 | 80 GiB（`scope=full` 建议 120 GiB） |
| 网络 | 可访问 GitHub、`deb.debian.org` |
| 权限 | runner 用户可无密码 `sudo apt-get` |

不要使用桌面版或带无关第三方 apt 源的机器。构建环境越干净，越容易复现。

## 2. 创建 VM

如果已有 Debian 13 VM，跳到第 3 节。使用 libvirt/virt-install 的示例：

```bash
sudo virt-install \
  --name kicad-builder \
  --memory 16384 \
  --vcpus 8 \
  --cpu host-passthrough \
  --disk size=80,format=qcow2 \
  --os-variant debian13 \
  --network network=default \
  --graphics none \
  --location https://deb.debian.org/debian/dists/trixie/main/installer-amd64/ \
  --extra-args "console=ttyS0"
```

也可以使用 Debian 13 cloud image、Proxmox、VMware 或物理机。安装完成后确认：

```bash
cat /etc/os-release
# ID=debian
# VERSION_ID="13"
uname -m
# x86_64
```

## 3. 基础配置

以具有 sudo 权限的管理员登录：

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl git jq sudo systemd zstd

sudo timedatectl set-timezone UTC
sudo systemctl enable --now systemd-timesyncd

# 专用 runner 用户（不要用 root 跑 runner）
sudo adduser --disabled-password --gecos "" ghrunner
sudo usermod -aG sudo ghrunner
```

磁盘检查：

```bash
df -h /
# 至少 40 GiB 可用；scope=arch 建议 60 GiB+
```

## 4. 最小 sudo 权限

脚本只通过 `sudo apt-get` 安装工具和 Build-Depends。给 runner 用户最小权限：

```bash
sudo tee /etc/sudoers.d/ghrunner-kicad >/dev/null <<'EOF'
Defaults:ghrunner env_keep += "DEBIAN_FRONTEND"
ghrunner ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt-mark, /usr/bin/dpkg
EOF
sudo chmod 0440 /etc/sudoers.d/ghrunner-kicad
sudo visudo -cf /etc/sudoers.d/ghrunner-kicad
```

验证：

```bash
sudo -u ghrunner sudo -n apt-get update
```

注意：`apt-get` 本身可以执行 maintainer scripts，因此这仍然是很高的权限。runner
必须是专用、只运行受信任 workflow 的机器。

## 5. 安装 GitHub Actions runner

在 GitHub 仓库页面进入 **Settings → Actions → Runners → New self-hosted runner**，
复制 registration token（有效期约 1 小时）。以下命令在 VM 上执行：

```bash
sudo mkdir -p /opt/actions-runner
sudo chown ghrunner:ghrunner /opt/actions-runner
sudo -u ghrunner -H bash <<'EOF'
set -euo pipefail
cd /opt/actions-runner

RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | jq -r '.tag_name' | sed 's/^v//')"
TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
BASE="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}"

curl -fSLO "${BASE}/${TARBALL}"
curl -fSLO "${BASE}/${TARBALL}.sha256"
sha256sum -c "${TARBALL}.sha256"
tar xzf "${TARBALL}"
EOF

# 安装 runner 的系统依赖（需要 root）
cd /opt/actions-runner
sudo ./bin/installdependencies.sh
```

配置 runner。把 `OWNER/REPO` 和 `TOKEN` 替换成实际值：

```bash
sudo -u ghrunner -H bash <<'EOF'
set -euo pipefail
cd /opt/actions-runner
./config.sh \
  --url https://github.com/OWNER/REPO \
  --token TOKEN \
  --name kicad-debian13-vm \
  --labels debian-13,kicad-builder \
  --work _work \
  --unattended \
  --replace
EOF
```

安装为系统服务：

```bash
cd /opt/actions-runner
sudo ./svc.sh install ghrunner
sudo ./svc.sh start
sudo ./svc.sh status
```

确认 GitHub 仓库的 **Settings → Actions → Runners** 中出现：

- 名称：`kicad-debian13-vm`
- 标签：`self-hosted`, `Linux`, `X64`, `debian-13`, `kicad-builder`
- 状态：Idle

`build.yml` 只依赖自定义标签 `debian-13` 和 `kicad-builder`，不依赖默认标签的
大小写。

## 6. 让 Release 使用 VM

在仓库 **Settings → Secrets and variables → Actions → Variables** 新建：

```text
KICAD_BUILD_RUNNER = self-hosted-vm
```

`release.yml` 会把它传给可复用构建 workflow。也可以在手动运行
`Build Debian package` 时直接选择 `self-hosted-vm`。

## 7. 首次验证

在 GitHub Actions 页面手动运行 **Build Debian package**：

- Runner: `self-hosted-vm`
- Scope: `arch`

观察：

1. `Prepare workspace` 是否成功（磁盘/内存检查）；
2. `Install packaging tools` 是否能用 sudo apt；
3. `Fetch and authenticate official Debian source` 是否通过签名校验；
4. `Resolve Build-Depends against Debian 13` 是否通过；
5. 编译是否成功；
6. 干净容器 smoke test 是否通过（该 job 在 GitHub 托管 runner 上运行，不在 VM 上）。

如果 runner 一直 queued，检查：

```bash
sudo systemctl status 'actions.runner.*'
sudo journalctl -u 'actions.runner.*' -n 100 --no-pager
```

## 8. 磁盘与缓存

`prepare-workspace.sh` 每次会删除 `build/` 和 `dist/`，但保留
`.cache/downloads`（约 260 MiB）。checkout 使用 `clean: true`，会清理未跟踪文件。

定期清理：

```bash
sudo apt-get clean
sudo -u ghrunner git -C /opt/actions-runner/_work/REPO/REPO clean -ffdx || true
df -h /
```

如果磁盘低于 10 GiB，构建脚本会直接失败；低于 20 GiB 会警告。无论哪种情况，
失败都不会产生半成品 Release。

## 9. 安全加固

- **只给受信任的人触发权限**。不要把这个 runner 接到公开 fork PR 的
  `pull_request` workflow；当前 `build.yml` 只支持 `workflow_dispatch` 和
  `workflow_call`（tag release）。
- **不要让 runner 保存发布私钥**。发布 job 固定在 GitHub 托管 runner 的
  `release` Environment 中执行。
- **专用 VM**。不要在上面跑个人任务、浏览器、即时通讯或不可信二进制。
- **最小 sudo**。只允许 `apt-get`/`apt-mark`/`dpkg`，不要给 `ALL=(ALL) NOPASSWD:ALL`。
- **定期重建**。建议每次发布后从快照重建，或至少每月重建。
- **防火墙**。只开放 SSH（限制来源）和出站 HTTPS；不要暴露其他端口。
- **自动更新**。构建期间避免 unattended-upgrades 修改工具链；可以配置维护窗口，
  或每次构建前手动更新并记录版本。

## 10. 故障排查

| 现象 | 处理 |
| --- | --- |
| job 一直 queued | runner 离线/标签不匹配；检查 `svc.sh status` 和仓库 Runners 页面 |
| `sudo: a password is required` | 检查 `/etc/sudoers.d/ghrunner-kicad`，用 `sudo -u ghrunner sudo -n true` 验证 |
| `dpkg-query`/`apt-get` 锁冲突 | 等待 unattended-upgrades 结束，或临时停用它 |
| 磁盘不足 | 清理 workspace、apt cache、旧 Docker 镜像；扩大磁盘 |
| `dscverify` 找不到 keyring | `sudo apt-get install debian-keyring` |
| 编译 OOM | 降低 `JOBS`（手动 workflow 目前使用脚本默认 `nproc`，可在 VM 上限制 CPU 或改脚本） |
| runner 版本过旧 | 重新运行 `config.sh --replace` 并升级 runner |

## 11. 回退到容器模式

删除或取消设置 `KICAD_BUILD_RUNNER`，`release.yml` 会回退到
`github-hosted`。手动 workflow 也可以直接选择 `github-hosted`。
