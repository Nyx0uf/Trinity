#!/bin/sh
set -eu

install_directory=${1:-}
case "$install_directory" in
	/*) ;;
	*)
		printf '%s\n' 'error: The Screen Savers directory must be an absolute path.' >&2
		exit 2
		;;
esac

saver_path="$install_directory/Trinity.saver"
build_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/trinity-install.XXXXXX")
staging_directory=

cleanup() {
	status=$?
	/bin/rm -rf "$build_directory" || status=1
	if [ -n "$staging_directory" ]; then
		# Restore the previous bundle if publishing the staged copy failed.
		if [ ! -e "$saver_path" ] && [ ! -L "$saver_path" ] &&
			{ [ -e "$staging_directory/previous" ] || [ -L "$staging_directory/previous" ]; }; then
			/bin/mv -f "$staging_directory/previous" "$saver_path" || exit 1
		fi
		/bin/rm -rf "$staging_directory" || status=1
	fi
	exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/bin/mkdir "$build_directory/Tmp"
printf '%s\n' 'Building Trinity.saver (Release)…'
TMPDIR="$build_directory/Tmp/" /usr/bin/xcrun xcodebuild -quiet \
	-project Trinity.xcodeproj -scheme Trinity -configuration Release \
	-destination 'platform=macOS,arch=arm64' \
	-derivedDataPath "$build_directory/DerivedData" build

# Stage on the destination volume and reserve the path against concurrent installs.
/bin/mkdir -p "$install_directory"
staging_path="$install_directory/.Trinity.saver.installing"
/bin/mkdir -m 700 "$staging_path"
staging_directory=$staging_path
/usr/bin/ditto "$build_directory/DerivedData/Build/Products/Release/Trinity.saver" "$staging_directory/new"

if [ -e "$saver_path" ] || [ -L "$saver_path" ]; then
	/bin/mv -f "$saver_path" "$staging_directory/previous"
fi
/bin/mv -f "$staging_directory/new" "$saver_path"
printf 'Installed %s\n' "$saver_path"
