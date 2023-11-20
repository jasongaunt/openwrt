#
# Copyright (C) 2016 lede-project.org
#

zyxel_get_rootfs() {
	local rootfsdev

	if read cmdline < /proc/cmdline; then
		case "$cmdline" in
			*root=*)
				rootfsdev="${cmdline##*root=}"
				rootfsdev="${rootfsdev%% *}"
			;;
		esac

		echo "${rootfsdev}"
	fi
}

zyxel_do_upgrade() {
	local tar_file="$1"
	local board=$(board_name)
	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	case "$board" in
	zyxel,wsq50|\
	zyxel,wsq60)
		# Identify our rootfs and kernel partitions
		local rootfs="$(zyxel_get_rootfs)"
		local kernel=
		local loop_supported=

		[ -b "${rootfs}" ] || return 1
		[ -f "/usr/sbin/losetup" ] && loop_supported=true

		case "$rootfs" in
			"/dev/mmcblk0p5")
				kernel="/dev/mmcblk0p4"
			;;
			"/dev/mmcblk0p8")
				kernel="/dev/mmcblk0p7"
			;;
			*)
				return 1
			;;
		esac

		# Stop / detach all loop devices if we can - if losetup is missing we will have limited storage
		[ "$loop_supported" = true ] && losetup --detach-all

		# Flash both kernel and rootfs
		echo "Flashing kernel to $kernel"
		tar xf $tar_file ${board_dir}/kernel -O >"${kernel}"

		echo "Flashing rootfs to ${rootfs}"
		tar xf $tar_file ${board_dir}/root -O >"${rootfs}"

		# Format new OverlayFS if we can
		if [ "$loop_supported" = true ]; then
			# Create a padded rootfs for overlay creation, reboot if failed
			local offset=$(tar xf $tar_file ${board_dir}/root -O | wc -c)
			[ $offset -lt 65536 ] && {
				echo "Wrong size for rootfs: ${offset}"
				sleep 10
				reboot -f
			}

			# Mount loop for rootfs_data
			local loopdev="$(losetup -f)"
			losetup -o $offset $loopdev $rootfs || {
				echo "Failed to mount looped rootfs_data."
				sleep 10
				reboot -f
			}

			# Format new rootfs_data
			echo "Format new rootfs_data at position ${offset}."
			mkfs.ext4 -F -L rootfs_data $loopdev
			mkdir /tmp/new_root
			mount -t ext4 $loopdev /tmp/new_root && {
				echo "Saving config to rootfs_data at position ${offset}."
				cp -v "$UPGRADE_BACKUP" "/tmp/new_root/$BACKUP_FILE"
				umount /tmp/new_root
			}

			# Cleanup
			losetup -d $loopdev >/dev/null 2>&1
			sync
			umount -a
			reboot -f
		fi
		;;
	*)
		tar Oxf $tar_file ${board_dir}/kernel | mtd write - kernel

		if [ -n "$UPGRADE_BACKUP" ]; then
			tar Oxf $tar_file ${board_dir}/root | mtd -j "$UPGRADE_BACKUP" write - rootfs
		else
			tar Oxf $tar_file ${board_dir}/root | mtd write - rootfs
		fi
		;;
	esac

	nand_do_upgrade "$1"

	return 0
}
