#!/bin/bash

if [ $UID -ne 0 ]; then
	echo "Must run as root"
	exit 1
fi

STAGING_DIR=staging
OUT_DIR=out

i=1
echo_color() {
	local color=$1
	shift
	local text="$*"

	case $color in
		black) 	 color_code="\033[0;30m" ;;
		red)   	 color_code="\033[0;31m" ;;
		green) 	 color_code="\033[0;32m" ;;
		yellow)  color_code="\033[0;33m" ;;
		blue)    color_code="\033[0;34m" ;;
		magenta) color_code="\033[0;35m" ;;
		cyan)    color_code="\033[0;36m" ;;
		white)   color_code="\033[0;37m" ;;
		*)       color_code="\033[0m" ;;
	esac

	echo -e "[$i] ${color_code}${text}\033[0m"
	i=$(($i + 1))
}

error() {
	echo_color red "$@"
	exit 1
}

usage() {
	echo_color blue "Usage: ./build.sh <device>"
	exit $1
}

download_if_missing() {
	echo_color blue "Downloading rootfs ($2) from $1"

	target_file=$STAGING_DIR/$2

	if [ ! -f $target_file ]; then
		wget $1 -O $target_file
	else
		echo_color blue "$target_file already exists"
	fi

	echo_color blue "Verifying $target_file"

	actual_hash=$(sha256sum "$target_file" | awk '{print $1}')
	if [ "$actual_hash" != "$2" ]; then
		echo_color red "Hashes mismatch (expected $2, got $actual_hash)"
		exit 1
	fi

	echo_color green "Hash verified successfully"
}

extract_rootfs_from_zip() {
	echo_color blue "Extracting rootfs from $1 to $2"

	unzip $STAGING_DIR/$1 data/rootfs.img -d $2
	mv $2/data/rootfs.img $2/rootfs.img
	rmdir $2/data

	echo_color green "Rootfs extracted"
}

DEVICE=$1

if [ -z $DEVICE ]; then
	usage 1
fi

DEVICE_DIR=devices/$DEVICE
DEVICE_CONFIG=$DEVICE_DIR/device-config.sh
DEVICE_ROOTFS=$DEVICE_DIR/rootfs

DEVICE_OUT=$OUT_DIR/$DEVICE

ROOTFS_IMAGE=$DEVICE_OUT/rootfs.img
ROOTFS_MOUNTPOINT=$DEVICE_OUT/rootfs

SPARSE_USERDATA_IMAGE=$DEVICE_OUT/userdata.img

USERDATA_IMAGE=$DEVICE_OUT/userdata.raw
USERDATA_MOUNTPOINT=$DEVICE_OUT/userdata

umount $ROOTFS_MOUNTPOINT
umount $USERDATA_MOUNTPOINT

if [ ! -f $DEVICE_CONFIG ]; then
	echo_color red "Device config does not exist at $DEVICE_CONFIG"
	exit 1
fi

unset BASE_ROOTFS_URL

source $DEVICE_CONFIG

if [ -z $BASE_ROOTFS_URL ]; then
	echo_color red "Missing BASE_ROOTFS_URL in $DEVICE_CONFIG"
	exit 1
fi

if [ -z $BASE_ROOTFS_SHA256 ]; then
	echo_color red "Missing BASE_ROOTFS_SHA256 in $DEVICE_CONFIG"
	exit 1
fi

if [ -z $USERDATA_IMAGE_SIZE ]; then
	echo_color red "Missing USERDATA_IMAGE_SIZE in $DEVICE_CONFIG"
	exit 1
fi

if [ -z $ROOTFS_IMAGE_SIZE ]; then
	echo_color red "Missing ROOTFS_IMAGE_SIZE in $DEVICE_CONFIG"
	exit 1
fi

echo_color blue "Building for $DEVICE"

rm -rf $DEVICE_OUT

mkdir -p $STAGING_DIR
mkdir -p $DEVICE_OUT

#
# Download rootfs
#
download_if_missing $BASE_ROOTFS_URL $BASE_ROOTFS_SHA256

#
# Extract rootfs
#
extract_rootfs_from_zip $BASE_ROOTFS_SHA256 $DEVICE_OUT

#
# Resize rootfs
#
echo_color blue "Resizing rootfs"

e2fsck -y -f $ROOTFS_IMAGE || error "Failed to verify the rootfs filesystem"
resize2fs -b $ROOTFS_IMAGE || error "Failed to convert rootfs to 64-bit"
resize2fs -f $ROOTFS_IMAGE $ROOTFS_IMAGE_SIZE || error "Failed to resize rootfs"

#
# Mount rootfs
#
echo_color blue "Mounting rootfs"
mkdir -p $ROOTFS_MOUNTPOINT || error "Failed to create $ROOTFS_MOUNTPOINT"
mount $ROOTFS_IMAGE $ROOTFS_MOUNTPOINT || error "Failed to mount $ROOTFS_IMAGE to $ROOTFS_MOUNTPOINT"

#
# Copy device rootfs changes
#
echo_color blue "Copying device rootfs"
cp -r $DEVICE_ROOTFS/. $ROOTFS_MOUNTPOINT || error "Failed to copy $DEVICE_ROOTFS to $ROOTFS_MOUNTPOINT"
echo_color green "Successfully copied device rootfs"

#
# Umount rootfs
#
echo_color blue "Unmounting rootfs"
umount $ROOTFS_MOUNTPOINT || error "Failed to unmount $ROOTFS_MOUNTPOINT"

#
# Generate userdata
#
echo_color blue "Generating userdata image"

mkdir -p $USERDATA_MOUNTPOINT || error "Failed to create $USERDATA_MOUNTPOINT"

echo_color blue "Generating empty userdata image"
truncate -s $USERDATA_IMAGE_SIZE $USERDATA_IMAGE || error "Failed to truncate $USERDATA_IMAGE TO $USERDATA_IMAGE_SIZE bytes"
mkfs.ext4 $USERDATA_IMAGE || error "Failed to create ext4 filesystem at $USERDATA_IMAGE"

echo_color blue "Copying rootfs"
mount $USERDATA_IMAGE $USERDATA_MOUNTPOINT || error "Failed to mount $USERDATA_IMAGE to $USERDATA_MOUNTPOINT"
cp $ROOTFS_IMAGE $USERDATA_MOUNTPOINT/rootfs.img || error "Failed to copy $ROOTFS_IMAGE to $USERDATA_MOUNTPOINT"
umount $USERDATA_MOUNTPOINT || error "Failed to unmount $USERDATA_MOUNTPOINT"

echo_color blue "Generating sparse userdata"
img2simg $USERDATA_IMAGE $SPARSE_USERDATA_IMAGE || error "Failed to generate sparse userdata"

#
# Create zip packages
#
echo_color blue "Packaging images"

echo_color yellow "rootfs.img is $(du -h $DEVICE_OUT/rootfs.img)"
echo_color yellow "userdata.img is $(du -h $DEVICE_OUT/userdata.img)"

cd $DEVICE_OUT || error "Failed to enter $DEVICE_OUT"
zip rootfs.zip rootfs.img || error "Failed to package rootfs"
zip userdata.zip userdata.img || error "Failed to package userdata"

echo_color green "Build finished"

