#!/usr/bin/env bash
#####################################################################
#   AVD Magisk Setup
#####################################################################
#
# Support API level: 23 - 34
#
# With an emulator booted and accessible via ADB, usage:
# ./build.py emulator
#
# This script will stop zygote, simulate the Magisk start up process
# that would've happened before zygote was started, and finally
# restart zygote. This is useful for setting up the emulator for
# developing Magisk, testing modules, and developing root apps using
# the official Android emulator (AVD) instead of a real device.
#
# This only covers the "core" features of Magisk. For testing
# magiskinit, please checkout avd_patch.sh.
#
#####################################################################

# 1. 将 magisk 解压到 /data/local/tmp 目录下
# 2. 将解压出来的 so 文件放到 /data/local/tmp 目录下
# 3. 将 /data/local/tmp 目录下的 so 文件加载到系统
# 4. 启动 magisk 的相关服务
# 5. 重启 zygote #

set -x # 调试模式

mount_sbin() {
  mount -t tmpfs -o 'mode=0755' magisk /sbin # 挂载临时文件系统到 /sbin 目录
  chcon u:object_r:rootfs:s0 /sbin           # 设置 /sbin 目录的安全上下文为 rootfs:s0;
}

if [ ! -f /system/build.prop ]; then
  # Running on PC
  echo 'Please run `./build.py emulator` instead of directly executing the script!'
  exit 1
fi

cd /data/local/tmp
chmod 755 busybox

# 如果环境变量 FIRST_STAGE 不存在或者值为空，那么就执行下面的代码。代码中通过设置 $FIRST_STAGE 属性来避免这段代码只会执行一次。所以下面的使用 root 权限重新执行这个脚本的时候就不会陷入死循环。
if [ -z "$FIRST_STAGE" ]; then
  export FIRST_STAGE=1
  export ASH_STANDALONE=1
  # 执行 busybox id -u 命令获取当前用户的uid, 并判断 id 是否等于 0
  if [ $(./busybox id -u) -ne 0 ]; then
    # Re-exec script with root。 $0 当前脚本名字: /data/local/tmp/avd_magisk.sh
    exec /system/xbin/su 0 ./busybox sh $0
  else
    # Re-exec script with busybox
    exec ./busybox sh $0
  fi
fi

pm install -r -g $(pwd)/magisk.apk

# Extract files from APK。
# -o 设置文件创建时间为最后修改的时间; -j 表示解压时不创建目录
unzip -oj magisk.apk 'assets/util_functions.sh' 'assets/stub.apk'
. ./util_functions.sh

# util_functions.sh 的命令，获取当前设备的 API、ABI、ABI32、IS64BIT 等信息，并设置以下变量的值：
# MAGISKBIN=/data/adb/magisk
# POSTFSDATAD=/data/adb/post-fs-data.d
# SERVICED=/data/adb/service.d
api_level_arch_detect

# 释放 lib 目录下的 so 文件到 /data/local/tmp 目录下，并修改名字去掉 lib 前缀和 .so 的后缀
unzip -oj magisk.apk "lib/$ABI/*" "lib/$ABI32/libmagisk32.so" -x "lib/$ABI/libbusybox.so"
for file in lib*.so; do
  chmod 755 $file
  # file:3:${#file}-5: 从第 3 个字符开始，截取 ${#file}-5 个字符; ${#file}-5: 获取 file 的长度，减去 5
  mv "$file" "${file:3:${#file}-6}"
done

# Stop zygote (and previous setup if exists)
magisk --stop 2>/dev/null # magisk 的命令，停止 magisk 的相关服务
stop

# 如果 /dev/avd-magisk 目录存在，就删除这个目录
if [ -d /debug_ramdisk ]; then
  # -l: Lazy unmount (detach from filesystem now, close when last user does)
  # 为什么用 -l 选项 ？Copilot: 因为 umount 命令默认是同步的，会等待所有的文件系统都卸载完毕才会返回，而使用 -l 选项则是异步的，会立即返回。
  umount -l /debug_ramdisk 2>/dev/null
fi

# Make sure boot completed props are not set to 1
setprop sys.boot_completed 0

# Mount /cache if not already mounted
# 日志文件。 !: 取反; grep -q: 不输出匹配行，只输出匹配行的行号
if ! grep -q ' /cache ' /proc/mounts; then
  # -t: 指定文件系统类型; -o: 指定挂载选项 mode=0755: 设置挂载目录的权限为 0755; tmpfs: 指定挂载的文件系统类型; /cache: 指定挂载的目录
  # tmpfs 是一种内存文件系统，这样系统在访问 /cache 目录时就会直接访问内存中的临时文件系统，可以大大提高文件访问速度。由于是临时文件系统，系统重启后会自动清空临时文件系统中的数据。
  mount -t tmpfs -o 'mode=0755' tmpfs /cache
fi

MAGISKTMP=/sbin

# Setup bin overlay
if mount | grep -q rootfs; then
  # Legacy rootfs
  mount -o rw,remount / # 重新挂载 / 目录为可读写; -o: 指定挂载选项 rw: 指定挂载为可读写; remount: 重新挂载
  rm -rf /root
  mkdir /root
  chmod 750 /root
  ln /sbin/* /root
  mount -o ro,remount /
  mount_sbin # 挂载临时文件系统到 /sbin 目录
  ln -s /root/* /sbin
elif [ -e /sbin ]; then
  # Legacy SAR
  mount_sbin
  mkdir -p /dev/sysroot
  block=$(mount | grep ' / ' | awk '{ print $1 }')
  [ $block = "/dev/root" ] && block=/dev/block/vda1
  mount -o ro $block /dev/sysroot
  for file in /dev/sysroot/sbin/*; do
    [ ! -e $file ] && break
    if [ -L $file ]; then
      cp -af $file /sbin
    else
      sfile=/sbin/$(basename $file)
      touch $sfile
      mount -o bind $file $sfile
    fi
  done
  umount -l /dev/sysroot
  rm -rf /dev/sysroot
else
  # Android Q+ without sbin Android 10 以上的版本
  MAGISKTMP=/debug_ramdisk
  # If a file name 'magisk' is in current directory, mount will fail
  rm -f magisk
  mount -t tmpfs -o 'mode=0755' magisk /debug_ramdisk
fi

# Magisk stuff
mkdir -p $MAGISKBIN 2>/dev/null # 创建 $MAGISKBIN; -p: 递归创建目录
unzip -oj magisk.apk 'assets/*.sh' -d $MAGISKBIN
mkdir $NVBASE/modules 2>/dev/null         # /data/adb/modules
mkdir $NVBASE/post-fs-data.d 2>/dev/null  # /data/adb/post-fs-data.d
mkdir $NVBASE/service.d 2>/dev/null       # /data/adb/service.d

for file in magisk32 magisk64 magiskpolicy stub.apk; do
  chmod 755 ./$file
  # -af 表示强制复制，即使目标文件已经存在
  cp -af ./$file $MAGISKTMP/$file # /dev/avd-magisk
  cp -af ./$file $MAGISKBIN/$file #/data/adb/magisk
done
cp -af ./magiskboot $MAGISKBIN/magiskboot
cp -af ./magiskinit $MAGISKBIN/magiskinit
cp -af ./busybox $MAGISKBIN/busybox

if $IS64BIT; then
  ln -s ./magisk64 $MAGISKTMP/magisk
else
  ln -s ./magisk32 $MAGISKTMP/magisk
fi
ln -s ./magisk $MAGISKTMP/su
ln -s ./magisk $MAGISKTMP/resetprop
ln -s ./magiskpolicy $MAGISKTMP/supolicy

mkdir -p $MAGISKTMP/.magisk/mirror
mkdir $MAGISKTMP/.magisk/block
mkdir $MAGISKTMP/.magisk/worker
touch $MAGISKTMP/.magisk/config

# 导出到环境变量 MAGISKTMP
export MAGISKTMP
# magisk 命令；MAKEDEV =1 : 生成设备节点
MAKEDEV=1 $MAGISKTMP/magisk --preinit-device 2>&1

RULESCMD=""
for r in $MAGISKTMP/.magisk/preinit/*/sepolicy.rule; do
  [ -f "$r" ] || continue
  RULESCMD="$RULESCMD --apply $r"
done

# SELinux stuffs
if [ -d /sys/fs/selinux ]; then
  if [ -f /vendor/etc/selinux/precompiled_sepolicy ]; then
    ./magiskpolicy --load /vendor/etc/selinux/precompiled_sepolicy --live --magisk $RULESCMD 2>&1
  elif [ -f /sepolicy ]; then
    ./magiskpolicy --load /sepolicy --live --magisk $RULESCMD 2>&1
  else
    ./magiskpolicy --live --magisk $RULESCMD 2>&1
  fi
fi

# Boot up
$MAGISKTMP/magisk --post-fs-data
start
$MAGISKTMP/magisk --service
