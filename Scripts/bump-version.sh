#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project="$root/Trinity.xcodeproj/project.xcproj"
lock="$root/Trinity.xcodeproj/.version-bump"

fail() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

/bin/mkdir "$lock" || fail "Could not acquire the version lock at $lock."
trap '/bin/rm -f "$lock/project.xcproj"; /bin/rmdir "$lock"' EXIT
trap 'exit 1' HUP INT TERM

version=$(sed -n 's/^[[:space:]]*"MARKETING_VERSION": "\(.*\)",$/\1/p' "$project")
build=$(sed -n 's/^[[:space:]]*"CURRENT_PROJECT_VERSION": "\(.*\)",$/\1/p' "$project")
case "$version" in
	*[!0-9.]*) fail "Expected one shared MARKETING_VERSION in YEAR.NUMBER_OF_RELEASE format." ;;
esac
printf '%s\n' "$version" | grep -Eq '^[1-9][0-9]{3}\.[1-9][0-9]*$' ||
	fail "Expected one shared MARKETING_VERSION in YEAR.NUMBER_OF_RELEASE format."
case "$build" in
	''|0*|*[!0-9]*) fail "Expected one shared positive integer CURRENT_PROJECT_VERSION." ;;
esac

year=$(date +%Y)
previous_year=${version%.*}
release=${version#*.}
if [ "$year" -lt "$previous_year" ]; then
	fail "The local year $year is earlier than the current release year $previous_year."
fi
if [ "$year" -gt "$previous_year" ]; then
	release=0
fi
next_version="$year.$((release + 1))"
next_build=$((build + 1))

sed -e "s/^\([[:space:]]*\"MARKETING_VERSION\": \"\)[0-9.]*\(\",\)$/\1$next_version\2/" \
	-e "s/^\([[:space:]]*\"CURRENT_PROJECT_VERSION\": \"\)[0-9]*\(\",\)$/\1$next_build\2/" \
	"$project" >"$lock/project.xcproj"
/bin/mv -f "$lock/project.xcproj" "$project"

printf 'Trinity and TrinityPreview %s (build %s)\n' "$next_version" "$next_build"
