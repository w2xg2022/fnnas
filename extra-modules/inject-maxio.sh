#!/bin/bash
#==========================================================================
# 把 Maxio MAE0621A PHY 驱动（out-of-tree 模块）注入已打包好的 FnNAS 镜像。
#
# 做法：从输出镜像取 KVER → 从 kernel_fnnas release 下载对应 headers →
# 用 aarch64 cross-compiler 在 x86 runner 上直接编出 maxio.ko → 注入镜像。
#
# 用法: inject-maxio.sh <output.img.gz> <module-src-dir>
#   本脚本需以 root 运行（由 workflow 用 sudo 调用）。
#   环境变量 GH_TOKEN（可选）用于 gh release download 认证。
#==========================================================================
set -euo pipefail

OUT_GZ="${1:?need output image .img.gz path}"
MODSRC="${2:?need module source dir}"

WORK="$(mktemp -d)"
OUT_LOOP=""
OUT_MNT=""

cleanup() {
	set +e
	[ -n "${OUT_MNT:-}" ] && { umount "${OUT_MNT}" 2>/dev/null; rmdir "${OUT_MNT}" 2>/dev/null; }
	[ -n "${OUT_LOOP}" ] && losetup -d "${OUT_LOOP}" 2>/dev/null
	rm -rf "${WORK}"
}
trap cleanup EXIT

mount_rootfs() {
	local img="$1" loop part mnt
	loop="$(losetup -Pf --show "${img}")"
	echo "${loop}" > "${WORK}/.lastloop"
	for part in "${loop}"p*; do
		[ -b "${part}" ] || continue
		mnt="$(mktemp -d)"
		if mount -o rw "${part}" "${mnt}" 2>/dev/null; then
			if [ -d "${mnt}/lib/modules" ]; then
				echo "${mnt}"
				return 0
			fi
			umount "${mnt}"
		fi
		rmdir "${mnt}" 2>/dev/null || true
	done
	return 1
}

# ---- 1) 打开输出镜像，取得目标内核版本 ----
echo "[maxio] output image: ${OUT_GZ}"
cp "${OUT_GZ}" "${WORK}/out.gz"
gunzip "${WORK}/out.gz"
OUT_IMG="${WORK}/out"
OUT_MNT="$(mount_rootfs "${OUT_IMG}")" || { echo "[maxio] ERROR: output rootfs not found"; exit 1; }
OUT_LOOP="$(cat "${WORK}/.lastloop")"
KVER="$(ls "${OUT_MNT}/lib/modules" | head -n1)"
echo "[maxio] target kernel = ${KVER}"

# ---- 2) 下载 kernel headers，交叉编译 maxio.ko ----
# 从 kernel_fnnas release 的 tarball 中提取 headers
KERN_TAG="kernel_fnnas"
# KVER 格式如 6.18.18-trim，tarball 路径如 6.18.18-rockchip/header-rockchip-6.18.18-trim.tar.gz
KBASE="${KVER%%-*}"           # 6.18.18
KSUFFIX="${KVER#*-}"          # trim
# 外层 tarball 名：<KBASE>-rockchip.tar.gz
OUTER_TAR="${KBASE}-rockchip.tar.gz"
HEADER_TAR="${KBASE}-rockchip/header-rockchip-${KVER}.tar.gz"

REPO="${GITHUB_REPOSITORY:-w2xg2022/fnnas}"
echo "[maxio] downloading headers from ${REPO} release ${KERN_TAG}..."
gh release download "${KERN_TAG}" -R "${REPO}" -p "${OUTER_TAR}" -D "${WORK}" --clobber

echo "[maxio] extracting headers..."
HDRDIR="${WORK}/headers"
mkdir -p "${HDRDIR}"
tar xzf "${WORK}/${OUTER_TAR}" -C "${WORK}" "${HEADER_TAR}"
tar xzf "${WORK}/${HEADER_TAR}" -C "${HDRDIR}"

# 创建 /lib/modules/KVER/build 指向 headers
FAKE_MODDIR="${WORK}/fake-modules/${KVER}"
mkdir -p "${FAKE_MODDIR}"
ln -s "${HDRDIR}" "${FAKE_MODDIR}/build"

# headers tarball 是在 arm64 环境打包的，scripts/ 下的 host tool（fixdep、modpost 等）
# 都是 aarch64 binary，在 x86 runner 上跑不了。删掉它们，让 make HOSTCC=gcc 重编成 x86。
echo "[maxio] cleaning arm64 host tools in headers..."
find "${HDRDIR}/scripts" -type f -executable 2>/dev/null | while read -r f; do
	if file "$f" 2>/dev/null | grep -q 'ELF.*aarch64'; then
		rm -f "$f"
	fi
done

echo "[maxio] cross-compiling maxio.ko for ${KVER}..."
make -C "${HDRDIR}" M="$(realpath "${MODSRC}")" \
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
	HOSTCC=gcc HOSTCXX=g++ \
	KVER="${KVER}" modules

BUILT_KO="$(realpath "${MODSRC}")/maxio.ko"
[ -f "${BUILT_KO}" ] || { echo "[maxio] ERROR: maxio.ko not produced"; exit 1; }
echo "[maxio] built: $(stat -c%s "${BUILT_KO}") bytes"

# ---- 3) 把 .ko 注入输出镜像 ----
echo "[maxio] installing module into output image..."
mkdir -p "${OUT_MNT}/lib/modules/${KVER}/updates"
cp "${BUILT_KO}" "${OUT_MNT}/lib/modules/${KVER}/updates/"

# depmod 需要在 arm64 环境执行（读 modules.dep 格式与架构相关）
# 用 qemu chroot 跑 depmod
cp /usr/bin/qemu-aarch64-static "${OUT_MNT}/usr/bin/" 2>/dev/null || true
mount --bind /proc "${OUT_MNT}/proc"
mount --bind /sys  "${OUT_MNT}/sys"
mount --bind /dev  "${OUT_MNT}/dev"
chroot "${OUT_MNT}" depmod -a "${KVER}"
umount "${OUT_MNT}/proc" "${OUT_MNT}/sys" "${OUT_MNT}/dev"
rm -f "${OUT_MNT}/usr/bin/qemu-aarch64-static"

echo "maxio" > "${OUT_MNT}/etc/modules-load.d/maxio.conf"

sync
umount "${OUT_MNT}"; OUT_MNT=""
losetup -d "${OUT_LOOP}"; OUT_LOOP=""

echo "[maxio] recompressing output image..."
gzip "${OUT_IMG}"
mv -f "${OUT_IMG}.gz" "${OUT_GZ}"
trap - EXIT
rm -rf "${WORK}"
echo "[maxio] done: ${OUT_GZ}"
