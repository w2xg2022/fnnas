# w2xg2022 / fnnas

> 🔧 个人云编译仓库 ｜ 姊妹仓：[Armbian](https://github.com/w2xg2022/armbian) · [FnOS / FnNAS（本仓）](https://github.com/w2xg2022/fnnas) · 内核源码 [armbian-kernel](https://github.com/w2xg2022/armbian-kernel)

本仓库 fork 自 [ophub/fnnas](https://github.com/ophub/fnnas)，用于**为新的电视盒子 / 开发板适配并云编译 [FnOS](https://fnnas.com/) 固件**。

FnOS 是基于最新 Linux 内核（Debian）深度定制的私有 NAS 系统，可以把闲置的电视盒子 / 开发板变成一台私有数据存储服务器。

适配成果（机型定义 model_database）也会通过 Pull Request **回馈共享到上游 ophub**，让更多人受益。

- 📦 固件下载：[Releases](https://github.com/w2xg2022/fnnas/releases)
- 🐧 Armbian 固件：[w2xg2022/armbian](https://github.com/w2xg2022/armbian)
- 账号密码：首次开机通过网页向导自建（非固定默认值）

## 已适配型号

<table>
<thead>
<tr>
<th nowrap>品牌</th><th nowrap>型号</th><th nowrap>芯片</th><th nowrap>架构</th><th nowrap>RAM+ROM</th><th nowrap>机型代号</th><th>固件</th>
</tr>
</thead>
<tbody>
<tr>
<td nowrap>浪潮</td><td nowrap>MD1000</td><td nowrap>RK3566</td><td nowrap>arm64</td><td nowrap>2+32</td><td nowrap><code>md1000</code></td><td><a href="https://github.com/w2xg2022/fnnas/releases">Releases</a></td>
</tr>
</tbody>
</table>

> 注：本仓库只服务 64 位（arm64）设备。完整的上游支持型号列表（数百款），参见下方「上游完整文档」。

## 如何获取固件

### 方法一：直接下载（普通用户推荐）

到 [Releases](https://github.com/w2xg2022/fnnas/releases) 下载文件名含**对应机型代号**（见上表「机型代号」列）的 `.img.gz`，解压后用 balenaEtcher / Rufus 写入 U 盘或 TF 卡，插入设备开机，按上游文档说明写入 eMMC。

### 方法二：云编译（GitHub Actions）

> ⚠️ 此方式面向**维护者 / 想自行编译的人**。GitHub 不允许在他人仓库触发 Actions，所以你需要先把本仓库 **Fork 到自己的账号**，在**你自己的 Fork** 里运行（只想要现成固件，请用方法一）。

在自己 Fork 的 **Actions** 页面手动触发，或用 `gh` 命令行（把 `<你的账号>` 换成你的 GitHub 账号）：

```bash
# ① 先封装内核（从 ophub/fnnas 官方 debs 重新打包，发布到本仓 kernel_fnnas）
gh workflow run build-fnnas-kernel.yml --repo <你的账号>/fnnas

# ② 内核好了之后，再打包固件（默认从本仓 kernel_fnnas 取内核）
gh workflow run build-fnnas-image.yml --repo <你的账号>/fnnas
```

fnnas 没有像 armbian 那样的自动接力机制，**两步需要手动依次触发**：先内核、内核成功后再固件。

要打包**哪个机型**，在触发 `build-fnnas-image.yml` 时用 `fnnas_board` 参数指定（见上表「机型代号」列），默认值为 `md1000`。

### 方法三：git 到本地编译（在 Ubuntu 22.04 / 24.04）

```bash
git clone https://github.com/w2xg2022/fnnas.git
cd fnnas

# 安装编译依赖
sudo apt-get update
sudo apt-get install -y $(cat make-fnnas/script/ubuntu2404-make-fnnas-depends)

# ① 封装内核
sudo ./rekernel -k 6.18.y

# ② 打包固件，<机型代号> 见上表（需先准备 FnOS 官方 arm64 基础镜像，详见上游文档）
sudo ./renas -b <机型代号> -k 6.18.y   # 例：-b md1000
```

> 本地编译的完整参数、写入 eMMC（`fnnas-install`）、内核更新（`fnnas-update`）等用法，参见上游文档：[ophub/fnnas](https://github.com/ophub/fnnas)。

## 如何适配一块新板子

1. 确认目标板子的 dtb 已存在于 [w2xg2022/armbian-kernel](https://github.com/w2xg2022/armbian-kernel)（fnnas 与 Armbian 共用同一份 dtb）；
2. 在本仓 `make-fnnas/fnnas-files/common-files/etc/model_database.conf` 增加一行机型定义（`FDTFILE` 指向对应 dtb、`BUILD=yes`）；
3. 触发 `build-fnnas-kernel.yml` 和 `build-fnnas-image.yml` 完成打包验证；
4. 适配成功后，向 [ophub/fnnas](https://github.com/ophub/fnnas) 提交 Pull Request 共享成果。

---

本仓库基于 [ophub/fnnas](https://github.com/ophub/fnnas)（GPL-2.0），感谢 ophub、coolsnowwolf、unifreq 等上游贡献者。完整功能说明（安装/升级/eMMC 备份还原/LED 控制等）与全量支持型号列表，请参见上游完整文档：[ophub/fnnas README](https://github.com/ophub/fnnas/blob/main/README.md)。
