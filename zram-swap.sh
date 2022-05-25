#!/bin/sh
# source: https://github.com/foundObjects/zram-swap
# shellcheck disable=SC2013,SC2039,SC2064

[ "$(id -u)" -eq '0' ] || { echo "This script requires root." && exit 1; }
case "$(readlink /proc/$$/exe)" in */bash) set -euo pipefail ;; *) set -eu ;; esac

# ensure a predictable environment
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
\unalias -a

# parse debug flag early so we can trace user configuration
[ "$#" -gt "0" ] && [ "$1" = "-x" ] && shift && set -x

# set sane defaults, see /etc/default/zram-swap for explanations
_zram_fraction="1/2"
_zram_algorithm="lz4"
_comp_factor=''
_zram_fixed_size=''
_zram_swap_debug=''
_zram_backing_dev=''
_zram_max_memory=''

# load user config
[ -f /etc/default/zram-swap ] &&
  . /etc/default/zram-swap

# support a debugging flag in the config file so people don't have to edit the systemd service
# to enable debugging
[ -n "$_zram_swap_debug" ] && set -x

# set expected compression ratio based on algorithm -- we'll use this to
# calculate how much uncompressed swap data we expect to fit into our
# target ram allocation.  skip if already set in user config
if [ -z "$_comp_factor" ]; then
  case $_zram_algorithm in
    lzo* | zstd) _comp_factor="3" ;;
    lz4) _comp_factor="2.5" ;;
    *) _comp_factor="2" ;;
  esac
fi

# main script:
_main() {
  if ! modprobe zram; then
    err "main: Failed to load zram module, exiting"
    return 1
  fi

  # make sure `set -u` doesn't cause 'case "$1"' to throw errors below
  { [ "$#" -eq "0" ] && set -- ""; } > /dev/null 2>&1

  case "$1" in
    "init" | "start")
      if grep -q zram /proc/swaps; then
        err "main: zram swap already in use, exiting"
        return 1
      fi
      _init
      ;;
    "end" | "stop")
      if ! grep -q zram /proc/swaps; then
        err "main: no zram swaps to cleanup, exiting"
        return 1
      fi
      _end
      ;;
    "restart")
      # TODO: stub for restart support
      echo "not supported yet"
      _usage
      exit 1
      ;;
    *)
      _usage
      exit 1
      ;;
  esac
}

# initialize swap
_init() {
  _total_mem=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  
  # calculate zram size
  if [ -n "$_zram_fixed_size" ]; then
    # check for valid size
    if ! _regex_match "$_zram_fixed_size" '^[[:digit:]]+(\.[[:digit:]]+)?(G|M)$'; then
      err "init: Invalid size '$_zram_fixed_size'. Format sizes like: 100M 250M 1.5G 2G etc."
      exit 1
    fi
    # Use user supplied zram size
    _zram_size="$_zram_fixed_size"
  else
    # Calculate zram size to use for zram
    _zram_size=$(calc "$_total_mem * $_comp_factor * $_zram_fraction * 1024")
  fi
  
  # calculate zram max memory
  if [ -n "$_zram_max_memory" ]; then
    # Auto: calculate max memory to use for zram
    if [ "$_zram_max_memory" = "auto" ]; then
      _zram_memory=$(calc "$_total_mem * $_zram_fraction * 1024")
    fi
    # check for valid size
    if ! _regex_match "$_zram_max_memory" '^[[:digit:]]+(\.[[:digit:]]+)?(G|M)$'; then
      err "init: Invalid size '$_zram_max_memory'. Format sizes like: 100M 250M 1.5G 2G etc."
      exit 1
    fi
    # Use user supplied zram max memory
    _zram_memory="$_zram_max_memory"
  fi

  # create zram device
  _device_id="$(cat /sys/class/zram-control/hot_add)"
  _device="/dev/zram$_device_id"
  if [ ! -b "$_device" ]; then
    err "init: Failed to initialize zram device"
    return 1
  fi

  # cleanup the device if swap setup fails
  trap "_rem_zdev $_device $_device_id" EXIT
  # REGION
    
  # set backing device
  if [ -b "$_zram_backing_dev" ]; then
    echo "$_zram_backing_dev" > "/sys/block/zram$_device_id/backing_dev"
  fi
  # set zram max memory
  if [ -n "$_zram_memory" ]; then
    echo "$_zram_memory" > "/sys/block/zram$_device_id/mem_limit"
  fi
  # set zram compress algorithm and disk size
  echo "$_zram_algorithm" > "/sys/block/zram$_device_id/comp_algorithm"
  echo "$_zram_size" > "/sys/block/zram$_device_id/disksize"
  # set writeback condition.
  if [ -b "$_zram_backing_dev" ]; then
    # TODO: configurable writeback condition
    # https://www.kernel.org/doc/html/v5.18/admin-guide/blockdev/zram.html
    echo "huge" > "/sys/block/zram$_device_id/writeback"
  fi
  # create swap and enable
  mkswap "$_device"
  swapon -d -p 15 "$_device"
    
  # ENDREGION
  trap - EXIT
  return 0
}

# end swapping and cleanup
_end() {
  ret="0"
  for dev in $(awk '/zram/ {print $1}' /proc/swaps); do
    swapoff "$dev"
    if ! _rem_zdev "$dev"; then
      err "end: Failed to remove zram device $dev"
      ret=1
    fi
  done
  return "$ret"
}

# Remove zram device with retry
_rem_zdev() {
  _device="$1"
  _device_id="$2"
  if [ ! -b "$_device" ]; then
    err "rem_zdev: No zram device '$1' to remove"
    return 1
  fi
  for i in $(seq 3); do
    # sleep for "0.1 * $i" seconds rounded to 2 digits
    sleep "$(calc 2 "0.1 * $i")"
    echo "$_device_id" > "/sys/class/zram-control/hot_remove"
    [ -b "$_device" ] || break
  done
  if [ -b "$_device" ]; then
    err "rem_zdev: Couldn't remove zram device '$1' after 3 attempts"
    return 1
  fi
  return 0
}

# posix substitute for bash pattern matching [[ $foo =~ bar-pattern ]]
# usage: _regex_match "$foo" "bar-pattern"
_regex_match() { echo "$1" | grep -Eq -- "$2" > /dev/null 2>&1; }

# calculate with variable precision
# usage: calc (int; precision := 0) (str; expr to evaluate)
calc() {
  _regex_match "$1" '^[[:digit:]]+$' && { n="$1" && shift; } || n=0
  LC_NUMERIC=C awk "BEGIN{printf \"%.${n}f\", $*}"
}

err() { echo "Err $*" >&2; }
_usage() { echo "Usage: $(basename "$0") (start|stop)"; }

_main "$@"
