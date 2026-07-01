#!/bin/bash
#==========================================================================
# 把 MD1000 板载千兆网口所需的 Maxio MAE0621A PHY 驱动，以 out-of-tree
# 模块形式注入到已打包好的 FnNAS 镜像里。
#
# FnNAS 内核来自 fnnas.com 官方预编译 deb，我们拿不到内核源码、无法把驱动
# 编进内核本体。而 ophub 的 renas 打包会把 /usr/src 内核头文件从「输出镜像」
# 里剥掉（省体积），因此输出镜像里编不了模块。
#
# 做法：从「官方 base 镜像」（完整、带 headers、内核版本与输出镜像一致）里用
# qemu chroot 原生编出 maxio.ko，再把 .ko 注入输出镜像（仅 cp + depmod + 开机
# 自动加载配置，不在输出镜像内编译）。
#
# 用法: inject-maxio.sh <output.img.gz> <module-src-dir> <base.img.xz>
#   本脚本需以 root 运行（由 workflow 用 sudo 调用）。
#==========================================================================
set -euo pipefail

OUT_GZ="${1:?need output image .img.gz path}"
MODSRC="${2:?need module source dir}"
BASE_XZ="${3:?need base image .img.xz path}"

WORK="$(mktemp -d)"
BASE_LOOP=""; OUT_LOOP=""
BASE_MNT=""; OUT_MNT=""

cleanup() {
	set +e
	for m in "${BASE_MNT:-}" "${OUT_MNT:-}"; do
		[ -n "${m}" ] || continue
		umount "${m}/proc" 2>/dev/null
		umount "${m}/sys"  2>/dev/null
		umount "${m}/dev"  2>/dev/null
		umount "${m}"      2>/dev/null
	done
	[ -n "${BASE_LOOP}" ] && losetup -d "${BASE_LOOP}" 2>/dev/null
	[ -n "${OUT_LOOP}" ]  && losetup -d "${OUT_LOOP}" 2>/dev/null
	rm -rf "${WORK}"
}
trap cleanup EXIT

# 挂载一个镜像文件的 rootfs 分区（含 /lib/modules 者），回显挂载点
mount_rootfs() {
	local img="$1" loop mnt part
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

# ---- 2) 从 base 镜像编出 maxio.ko（版本魔数需与目标内核一致）----
echo "[maxio] decompressing base image..."
xz -dc "${BASE_XZ}" > "${WORK}/base.img"
BASE_MNT="$(mount_rootfs "${WORK}/base.img")" || { echo "[maxio] ERROR: base rootfs not found"; exit 1; }
BASE_LOOP="$(cat "${WORK}/.lastloop")"

if [ ! -d "${BASE_MNT}/lib/modules/${KVER}/build" ]; then
	echo "[maxio] ERROR: base image lacks build tree for ${KVER}"
	echo "[maxio] base has: $(ls "${BASE_MNT}/lib/modules" 2>/dev/null)"
	exit 1
fi

cp /usr/bin/qemu-aarch64-static "${BASE_MNT}/usr/bin/" 2>/dev/null || true
mkdir -p "${BASE_MNT}/tmp/maxio-build"
cp "${MODSRC}/maxio.c" "${MODSRC}/Makefile" "${BASE_MNT}/tmp/maxio-build/"
mount --bind /proc "${BASE_MNT}/proc"
mount --bind /sys  "${BASE_MNT}/sys"
mount --bind /dev  "${BASE_MNT}/dev"

echo "[maxio] building maxio.ko for ${KVER} (qemu chroot on base image)..."
chroot "${BASE_MNT}" /bin/bash -c "cd /tmp/maxio-build && make KVER=${KVER}"
cp "${BASE_MNT}/tmp/maxio-build/maxio.ko" "${WORK}/maxio.ko"
echo "[maxio] built: $(ls -l "${WORK}/maxio.ko" | awk '{print $5}') bytes"

# 释放 base
rm -rf "${BASE_MNT}/tmp/maxio-build" "${BASE_MNT}/usr/bin/qemu-aarch64-static"
umount "${BASE_MNT}/proc" "${BASE_MNT}/sys" "${BASE_MNT}/dev"
umount "${BASE_MNT}"; BASE_MNT=""
losetup -d "${BASE_LOOP}"; BASE_LOOP=""
rm -f "${WORK}/base.img"

# ---- 3) 把 .ko 注入输出镜像 ----
echo "[maxio] installing module + boot autoload into output image..."
mkdir -p "${OUT_MNT}/lib/modules/${KVER}/updates"
cp "${WORK}/maxio.ko" "${OUT_MNT}/lib/modules/${KVER}/updates/"

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
