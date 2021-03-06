#!/bin/bash
set -e

# log arguments with timestamp
function log {
  if [ -z "$*" ]; then
    return 1
  fi

  TIMESTAMP=$(date '+%F %T')
  echo "${TIMESTAMP}  $0: $*"
  return 0
}

# ceph config file exists or die
function check_config {
  if [[ ! -e /etc/ceph/${CLUSTER}.conf ]]; then
    log "ERROR- /etc/ceph/${CLUSTER}.conf must exist; get it from your existing mon"
    exit 1
  fi
}

# ceph admin key exists or die
function check_admin_key {
  if [[ ! -e $ADMIN_KEYRING ]]; then
      log "ERROR- $ADMIN_KEYRING must exist; get it from your existing mon"
      exit 1
  fi
}

# Given two strings, return the length of the shared prefix
function prefix_length {
  local maxlen=${#1}
  for ((i=maxlen-1;i>=0;i--)); do
    if [[ "${1:0:i}" == "${2:0:i}" ]]; then
      echo $i
      return
    fi
  done
}

# Test if a command line tool is available
function is_available {
  command -v $@ &>/dev/null
}

# create the mandatory directories
function create_mandatory_directories {
  # Let's create the bootstrap directories
  for keyring in $OSD_BOOTSTRAP_KEYRING $MDS_BOOTSTRAP_KEYRING $RGW_BOOTSTRAP_KEYRING; do
    mkdir -p $(dirname $keyring)
  done

  # Let's create the ceph directories
  for directory in mon osd mds radosgw tmp mgr; do
    mkdir -p /var/lib/ceph/$directory
  done

  # Make the monitor directory
  mkdir -p "$MON_DATA_DIR"

  # Create socket directory
  mkdir -p /var/run/ceph

  # Creating rados directories
  mkdir -p /var/lib/ceph/radosgw/${RGW_NAME}

  # Create the MDS directory
  mkdir -p /var/lib/ceph/mds/${CLUSTER}-${MDS_NAME}

  # Create the MGR directory
  mkdir -p /var/lib/ceph/mgr/${CLUSTER}-$MGR_NAME

  # Adjust the owner of all those directories
  chown --verbose -R ceph. /var/run/ceph/ /var/lib/ceph/*
}

# Print resolved symbolic links of a device
function resolve_symlink {
  readlink -f ${@}
}

# Calculate proper device names, given a device and partition number
function dev_part {
  local osd_device=${1}
  local osd_partition=${2}

  if [[ -L ${osd_device} ]]; then
    # This device is a symlink. Work out it's actual device
    local actual_device=$(resolve_symlink ${osd_device})
    local bn=$(basename ${osd_device})
    if [[ "${actual_device:0-1:1}" == [0-9] ]]; then
      local desired_partition="${actual_device}p${osd_partition}"
    else
      local desired_partition="${actual_device}${osd_partition}"
    fi
    # Now search for a symlink in the directory of $osd_device
    # that has the correct desired partition, and the longest
    # shared prefix with the original symlink
    local symdir=$(dirname ${osd_device})
    local link=""
    local pfxlen=0
    for option in $(ls $symdir); do
    if [[ $(resolve_symlink $symdir/$option) == $desired_partition ]]; then
      local optprefixlen=$(prefix_length $option $bn)
      if [[ $optprefixlen > $pfxlen ]]; then
        link=$symdir/$option
        pfxlen=$optprefixlen
      fi
    fi
    done
    if [[ $pfxlen -eq 0 ]]; then
      >&2 log "Could not locate appropriate symlink for partition ${osd_partition} of ${osd_device}"
      exit 1
    fi
    echo "$link"
  elif [[ "${osd_device:0-1:1}" == [0-9] ]]; then
    echo "${osd_device}p${osd_partition}"
  else
    echo "${osd_device}${osd_partition}"
  fi
}

function osd_trying_to_determine_scenario {
  if [ -z "${OSD_DEVICE}" ]; then
    log "Bootstrapped OSD(s) found; using OSD directory"
    source osd_directory.sh
    osd_directory
  elif $(parted --script ${OSD_DEVICE} print | egrep -sq '^ 1.*ceph data'); then
    log "Bootstrapped OSD found; activating ${OSD_DEVICE}"
    source osd_disk_activate.sh
    osd_activate
  else
    log "Device detected, assuming ceph-disk scenario is desired"
    log "Preparing and activating ${OSD_DEVICE}"
    osd_disk
  fi
}

function get_osd_dev {
  for i in ${OSD_DISKS}
   do
    osd_id=$(echo ${i}|sed 's/\(.*\):\(.*\)/\1/')
    osd_dev="/dev/$(echo ${i}|sed 's/\(.*\):\(.*\)/\2/')"
    if [ ${osd_id} = ${1} ]; then
      echo -n "${osd_dev}"
    fi
  done
}

function unsupported_scenario {
  echo "ERROR: '${CEPH_DAEMON}' scenario or key/value store '${KV_TYPE}' is not supported by this distribution."
  echo "ERROR: for the list of supported scenarios, please refer to your vendor."
  exit 1
}

function is_integer {
  # This function is about saying if the passed argument is an integer
  # Supports also negative integers
  # We use $@ here to consider everything given as parameter and not only the
  # first one : that's mainly for splited strings like "10 10"
  [[ $@ =~ ^-?[0-9]+$ ]]
}

# Transform any set of strings to lowercase
function to_lowercase {
  echo "${@,,}"
}

# Transform any set of strings to uppercase
function to_uppercase {
  echo "${@^^}"
}

# Replace any variable separated with comma with space
# e.g: DEBUG=foo,bar will become:
# echo ${DEBUG//,/ }
# foo bar
function comma_to_space {
  echo "${@//,/ }"
}

# Get based distro by discovering the package manager
function get_package_manager {
  if is_available rpm; then
    OS_VENDOR=redhat
  elif is_available dpkg; then
    OS_VENDOR=ubuntu
  fi
}

# Determine if current distribution is an Ubuntu-based distribution
function is_ubuntu {
  get_package_manager
  [[ "$OS_VENDOR" == "ubuntu" ]]
}

# Determine if current distribution is a RedHat-based distribution
function is_redhat {
  get_package_manager
  [[ "$OS_VENDOR" == "redhat" ]]
}

# Wait for a file to exist, regardless of the type
function wait_for_file {
  timeout 10 bash -c "while [ ! -e ${1} ]; do echo 'Waiting for ${1} to show up' && sleep 1 ; done"
}

function valid_scenarios {
  if [ -n "$EXCLUDED_TAGS" ]; then
    for tag in $EXCLUDED_TAGS; do
      ALL_SCENARIOS=${ALL_SCENARIOS/$tag /}
    done
  fi
  log "Valid values for CEPH_DAEMON are $(to_uppercase $ALL_SCENARIOS)."
  log "Valid values for the daemon parameter are $ALL_SCENARIOS"
}

function invalid_ceph_daemon {
  if [ -z "$CEPH_DAEMON" ]; then
    log "ERROR- One of CEPH_DAEMON or a daemon parameter must be defined as the name of the daemon you want to deploy."
    valid_scenarios
    exit 1
  else
    log "ERROR- unrecognized scenario."
    valid_scenarios
  fi
}

function get_osd_path {
  echo "$OSD_PATH_BASE-$1/"
}

# List all the partitions on a block device
function list_dev_partitions {
  # We need to remove the /dev/ part of the device name
  # since /proc/partitions has entries like sda only.
  # However we return a complete device name e.g: /dev/sda
  for args in ${@}; do
    for p in $(egrep -o ${args#/dev/}[0-9] /proc/partitions); do
      echo "/dev/$p"
    done
  done
}

# Find the typecode of a partition
function get_part_typecode {
  for part in ${@}; do
    sgdisk --info=${part: -1} ${part%?} | awk '/Partition GUID code/ {print tolower($4)}'
  done
}

function apply_ceph_ownership_to_disks {
  if [[ -n "${OSD_JOURNAL}" ]]; then
    wait_for_file ${OSD_JOURNAL}
    chown --verbose ceph. ${OSD_JOURNAL}
  elif [[ ${OSD_DMCRYPT} -eq 1 ]]; then
    # apply permission on the lockbox partition
    wait_for_file $(dev_part ${OSD_DEVICE} 3)
    chown --verbose ceph. $(dev_part ${OSD_DEVICE} 3)
  elif [[ ${OSD_BLUESTORE} -eq 1 ]]; then
    dev_real_path=$(resolve_symlink $OSD_BLUESTORE_BLOCK_WAL $OSD_BLUESTORE_BLOCK_DB)
    for partition in $(list_dev_partitions $OSD_DEVICE $dev_real_path); do
      part_code="$(get_part_typecode $partition)"
      if [[ "$part_code" == "5ce17fce-4087-4169-b7ff-056cc58472be" ||
            "$part_code" == "5ce17fce-4087-4169-b7ff-056cc58473f9" ||
            "$part_code" == "30cd0809-c2b2-499c-8879-2d6b785292be" ||
            "$part_code" == "30cd0809-c2b2-499c-8879-2d6b78529876" ||
            "$part_code" == "89c57f98-2fe5-4dc0-89c1-f3ad0ceff2be" ||
            "$part_code" == "cafecafe-9b03-4f30-b4c6-b4b80ceff106" ]]; then
        chown --verbose ceph. $partition
      fi
    done
  else
    wait_for_file $(dev_part ${OSD_DEVICE} 2)
    chown --verbose ceph. $(dev_part ${OSD_DEVICE} 2)
  fi
  chown --verbose ceph. $(dev_part ${OSD_DEVICE} 1)
}

# Get partition uuid of a given partition
function get_part_uuid {
  blkid -o value -s PARTUUID ${1}
}
