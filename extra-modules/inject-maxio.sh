#!/bin/bash
#==========================================================================
# 把 MD1000 板载千兆网口所需的 Maxio MAE0621A PHY 驱动，以 out-of-tree
# 模块形式注入到已打包好的 FnNAS 镜像里。
#
# FnNAS 内核来自 fnnas.com 官方预编译 deb，我们拿不到内核源码、无法把驱动
# 编进内核本体；因此在打包完成后挂载镜像，用镜像自带的 headers + gcc（通过
# qemu chroot 原生编译）生成 maxio.ko，装进 /lib/modules/<ver>/updates/，
# 并配置开机自动加载。
#
# 用法: inject-maxio.sh <image.img.gz> <module-src-dir>
#   本脚本需以 root 运行（由 workflow 用 sudo 调用）。
#==========================================================================
set -euo pipefail

IMG_GZ="${1:?need image.img.gz path}"
MODSRC="${2:?need module source dir}"

echo "[maxio] processing: ${IMG_GZ}"
work="$(mktemp -d)"
cp "${IMG_GZ}" "${work}/img.gz"
gunzip "${work}/img.gz"
IMG="${work}/img"

loop="$(losetup -Pf --show "${IMG}")"
echo "[maxio] loop = ${loop}"

cleanup() {
	set +e
	[ -n "${ROOT_MNT:-}" ] && {
		umount "${ROOT_MNT}/proc" 2>/dev/null
		umount "${ROOT_MNT}/sys"  2>/dev/null
		umount "${ROOT_MNT}/dev"  2>/dev/null
		umount "${ROOT_MNT}"      2>/dev/null
	}
	[ -n "${loop:-}" ] && losetup -d "${loop}" 2>/dev/null
}
trap cleanup EXIT

# 找到含 /lib/modules 的 rootfs 分区
ROOT_MNT=""
for part in "${loop}"p*; do
	[ -b "${part}" ] || continue
	mnt="$(mktemp -d)"
	if mount -o rw "${part}" "${mnt}" 2>/dev/null; then
		if [ -d "${mnt}/lib/modules" ]; then
			ROOT_MNT="${mnt}"
			echo "[maxio] rootfs = ${part}"
			break
		fi
		umount "${mnt}"
	fi
	rmdir "${mnt}" 2>/dev/null || true
done
[ -n "${ROOT_MNT}" ] || { echo "[maxio] ERROR: rootfs partition not found"; exit 1; }

KVER="$(ls "${ROOT_MNT}/lib/modules" | head -n1)"
echo "[maxio] kernel = ${KVER}"
[ -d "${ROOT_MNT}/lib/modules/${KVER}/build" ] || {
	echo "[maxio] ERROR: kernel headers/build tree missing in image"; exit 1;
}

# 准备 qemu，供 x86 runner chroot 进 arm64 rootfs 执行原生编译
cp /usr/bin/qemu-aarch64-static "${ROOT_MNT}/usr/bin/" 2>/dev/null || true
mkdir -p "${ROOT_MNT}/tmp/maxio-build"
cp "${MODSRC}/maxio.c" "${MODSRC}/Makefile" "${ROOT_MNT}/tmp/maxio-build/"

mount --bind /proc "${ROOT_MNT}/proc"
mount --bind /sys  "${ROOT_MNT}/sys"
mount --bind /dev  "${ROOT_MNT}/dev"

echo "[maxio] building module inside image (qemu chroot)..."
chroot "${ROOT_MNT}" /bin/bash -c "cd /tmp/maxio-build && make KVER=${KVER}"

echo "[maxio] installing module + boot autoload..."
mkdir -p "${ROOT_MNT}/lib/modules/${KVER}/updates"
cp "${ROOT_MNT}/tmp/maxio-build/maxio.ko" "${ROOT_MNT}/lib/modules/${KVER}/updates/"
chroot "${ROOT_MNT}" depmod -a "${KVER}"
echo "maxio" > "${ROOT_MNT}/etc/modules-load.d/maxio.conf"

# 清理临时文件与 qemu
rm -rf "${ROOT_MNT}/tmp/maxio-build"
rm -f  "${ROOT_MNT}/usr/bin/qemu-aarch64-static"

umount "${ROOT_MNT}/proc"
umount "${ROOT_MNT}/sys"
umount "${ROOT_MNT}/dev"
sync
umount "${ROOT_MNT}"
losetup -d "${loop}"
trap - EXIT

echo "[maxio] recompressing..."
gzip "${IMG}"
mv -f "${IMG}.gz" "${IMG_GZ}"
rm -rf "${work}"
echo "[maxio] done: ${IMG_GZ}"
