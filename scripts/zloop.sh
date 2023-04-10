#!/usr/bin/env bash

#
# CDDL HEADER START
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#
# CDDL HEADER END
#

#
# Copyright (c) 2015, 2023 by Delphix. All rights reserved.
# Copyright (C) 2016 Lawrence Livermore National Security, LLC.
# Copyright (c) 2017, Intel Corporation.
#

BASE_DIR=${0%/*}
SCRIPT_COMMON=common.sh
if [[ -f "${BASE_DIR}/${SCRIPT_COMMON}" ]]; then
	. "${BASE_DIR}/${SCRIPT_COMMON}"
else
	echo "Missing helper script ${SCRIPT_COMMON}" && exit 1
fi

# shellcheck disable=SC2034
PROG=zloop.sh
GDB=${GDB:-gdb}

AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
AZURE_ACCOUNT=${AZURE_ACCOUNT:-}
AZURE_KEY=${AZURE_KEY:-}
ZTS_OBJECT_STORE=${ZTS_OBJECT_STORE:-}
ZTS_OBJECT_ENDPOINT=${ZTS_OBJECT_ENDPOINT:-}
ZTS_REGION=${ZTS_REGION:-}
ZTS_BUCKET_NAME=${ZTS_BUCKET_NAME:-}

DEFAULTWORKDIR=/var/tmp
DEFAULTCOREDIR=/var/tmp/zloop

function usage
{
	cat >&2 <<EOF

$0 [-hl] [-c <dump directory>] [-f <vdev directory>]
  [-m <max core dumps>] [-s <vdev size>] [-t <timeout>]
  [-I <max iterations>] [-- [extra ztest parameters]]

  This script runs ztest repeatedly with randomized arguments.
  If a crash is encountered, the ztest logs, any associated
  vdev files, and core file (if one exists) are moved to the
  output directory ($DEFAULTCOREDIR by default). Any options
  after the -- end-of-options marker will be passed to ztest.

  Options:
    -c  Specify a core dump directory to use.
    -f  Specify working directory for ztest vdev files.
    -h  Print this help message.
    -l  Create 'ztest.core.N' symlink to core directory.
    -m  Max number of core dumps to allow before exiting.
    -s  Size of vdev devices.
    -t  Total time to loop for, in seconds. If not provided,
        zloop runs forever.
    -I  Max number of iterations to loop before exiting.

EOF
}

function or_die
{
	if ! "$@"; then
		echo "Command failed: $*"
		exit 1
	fi
}

case $(uname) in
FreeBSD)
	coreglob="z*.core"
	;;
Linux)
	# core file helpers
	read -r origcorepattern </proc/sys/kernel/core_pattern
	coreglob="$(grep -E -o '^([^|%[:space:]]*)' /proc/sys/kernel/core_pattern)*"

	if [[ $coreglob = "*" ]]; then
		echo "Setting core file pattern..."
		echo "core" > /proc/sys/kernel/core_pattern
		coreglob="$(grep -E -o '^([^|%[:space:]]*)' \
		    /proc/sys/kernel/core_pattern)*"
	fi
	;;
*)
	exit 1
	;;
esac

function core_file
{
	# shellcheck disable=SC2012,SC2086
	ls -tr1 $coreglob 2>/dev/null | head -1
}

function core_prog
{
	# shellcheck disable=SC2154
	prog=$ZTEST
	core_id=$($GDB --batch -c "$1" | grep "Core was generated by" | \
	    tr  \' ' ')
	if [[ "$core_id" == *"zdb "* ]]; then
		# shellcheck disable=SC2154
		prog=$ZDB
	fi
	printf "%s" "$prog"
}

function store_core
{
	core="$(core_file)"
	if [[ $ztrc -ne 0 ]] || [[ -f "$core" ]]; then
		df -h "$workdir" >>ztest.out
		coreid=$(date "+zloop-%y%m%d-%H%M%S")
		foundcrashes=$((foundcrashes + 1))
		dest=$coredir/$coreid
		or_die mkdir -p "$dest/vdev"

		# zdb debugging
		if [[ -e "$workdir/zpool.cache" ]]; then
			zdbopt="-dddMmDDG"
			if [[ -n "$ZTS_OBJECT_STORE" ]]; then
				if [[ $ZTS_OBJECT_STORE == "s3" ]]; then
					zdbopt+=" -a $ZTS_OBJECT_ENDPOINT"
					zdbopt+=" -g $ZTS_REGION"
					[[ -z "$ZTS_CREDS_PROFILE" ]] && \
					    ZTS_CREDS_PROFILE="default"
					if ! is_using_iam_role; then
						zdbopt+=" -f"
						zdbopt+=" $ZTS_CREDS_PROFILE"
					fi
				fi
				zdbopt+=" -B $ZTS_BUCKET_NAME"
				zdbopt+=" -T $ZTS_OBJECT_STORE"
			fi
			zdbcmd="$ZDB -U $workdir/zpool.cache $zdbopt ztest"
			zdbdebug=$($zdbcmd 2>&1)
			echo -e "$zdbcmd\n" >>"$dest/ztest.zdb"
			echo "$zdbdebug" >>"$dest/ztest.zdb"
		fi

		if [[ $symlink -ne 0 ]]; then
			or_die ln -sf "$dest" "ztest.core.${foundcrashes}"
		fi

		echo "*** ztest crash found - moving logs to $dest"

		or_die mv ztest.history ztest.out "$dest/"

		if [[ -z "$ZTS_OBJECT_STORE" ]]; then
			or_die mv "$workdir/"ztest* "$dest/vdev/"
		fi

		if [[ -e "$workdir/zpool.cache" ]]; then
			or_die mv "$workdir/zpool.cache" "$dest/vdev/"
		fi

		# check for core
		if [[ -f "$core" ]]; then
			coreprog=$(core_prog "$core")
			coredebug=$($GDB --batch --quiet \
			    -ex "set print thread-events off" \
			    -ex "printf \"*\n* Backtrace \n*\n\"" \
			    -ex "bt" \
			    -ex "printf \"*\n* Libraries \n*\n\"" \
			    -ex "info sharedlib" \
			    -ex "printf \"*\n* Threads (full) \n*\n\"" \
			    -ex "info threads" \
			    -ex "printf \"*\n* Backtraces \n*\n\"" \
			    -ex "thread apply all bt" \
			    -ex "printf \"*\n* Backtraces (full) \n*\n\"" \
			    -ex "thread apply all bt full" \
			    -ex "quit" "$coreprog" "$core" 2>&1 | \
			    grep -v "New LWP")

			# Dump core + logs to stored directory
			echo "$coredebug" >>"$dest/ztest.gdb"
			or_die mv "$core" "$dest/"

			# Record info in cores logfile
			echo "*** core @ $coredir/$coreid/$core:" | \
			    tee -a ztest.cores
		fi

		if [[ $coremax -gt 0 ]] &&
		   [[ $foundcrashes -ge $coremax ]]; then
			echo "exiting... max $coremax allowed cores"
			exit 1
		else
			echo "continuing..."
		fi
	fi
}

# Checks if backend credentials are available for the connectivity test
credentials_in_env() {
	case $ZTS_OBJECT_STORE in
	blob)
		if [[ -n "$AZURE_ACCOUNT" ]] && \
		    [[ -n "$AZURE_KEY" ]]; then
			return 0
		fi
		;;
	s3|true)
		if [[ -n "$AWS_ACCESS_KEY_ID" ]] && \
		    [[ -n "$AWS_SECRET_ACCESS_KEY" ]]; then \
			return 0
		fi
		;;
	*)
		return 1
		;;
	esac
	return 1
}

# Configures and sets the object storage credentials to the disk
configure_object_store_credentials() {
	case $ZTS_OBJECT_STORE in
	blob)
		mkdir -p ~/.azure
		echo "[default]" > ~/.azure/credentials
		echo "AZURE_ACCOUNT = $AZURE_ACCOUNT" >> ~/.azure/credentials
		echo "AZURE_KEY = $AZURE_KEY" >> ~/.azure/credentials
		sudo mkdir -p /root/.azure && \
		    sudo cp ~/.azure/credentials /root/.azure/credentials
		;;
	s3|true)
		# Check and comment out the AWS_ environment variables
		# from the /etc/environment file
		if grep -q "^AWS" /etc/environment 2>/dev/null; then
			sudo sed -i "s/^AWS/# AWS/g" /etc/environment
		fi
		# If aws cli is installed and is in path
		if command -v aws >/dev/null 2>&1; then
			aws configure set aws_access_key_id \
			    "$AWS_ACCESS_KEY_ID"
			aws configure set aws_secret_access_key \
			    "$AWS_SECRET_ACCESS_KEY"
			sudo mkdir -p /root/.aws && \
			    sudo cp ~/.aws/credentials /root/.aws/credentials
		fi
		;;
	*)
		echo "Uknown object store: $ZTS_OBJECT_STORE"
		exit 1
		;;
	esac
}

#
# Determine if the test is using an IAM role to access the S3 bucket
# or via the secret keys
#
# Return 0 if using IAM, 1 if otherwise
#
function is_using_iam_role
{
	# When using IAM role both of the env variables AWS_SECRET_ACCESS_KEY
	# and AWS_ACCESS_KEY_ID remains empty or zero length
	if [[ -n "$AWS_ACCESS_KEY_ID" ]] && \
		[[ -n "$AWS_SECRET_ACCESS_KEY" ]]; then
		return 1
	fi
	return 0
}

# parse arguments
# expected format: zloop [-t timeout] [-c coredir] [-- extra ztest args]
coredir=$DEFAULTCOREDIR
basedir=$DEFAULTWORKDIR
rundir="zloop-run"
timeout=0
size="512m"
coremax=0
symlink=0
iterations=0
while getopts ":ht:m:I:s:c:f:l" opt; do
	case $opt in
		t ) [[ $OPTARG -gt 0 ]] && timeout=$OPTARG ;;
		m ) [[ $OPTARG -gt 0 ]] && coremax=$OPTARG ;;
		I ) [[ -n $OPTARG ]] && iterations=$OPTARG ;;
		s ) [[ -n $OPTARG ]] && size=$OPTARG ;;
		c ) [[ -n $OPTARG ]] && coredir=$OPTARG ;;
		f ) [[ -n $OPTARG ]] && basedir=$(readlink -f "$OPTARG") ;;
		l ) symlink=1 ;;
		h ) usage
		    exit 2
		    ;;
		* ) echo "Invalid argument: -$OPTARG";
		    usage
		    exit 1
	esac
done
# pass remaining arguments on to ztest
shift $((OPTIND - 1))

# enable core dumps
ulimit -c unlimited
export ASAN_OPTIONS=abort_on_error=true:halt_on_error=true:allocator_may_return_null=true:disable_coredump=false:detect_stack_use_after_return=true
export UBSAN_OPTIONS=abort_on_error=true:halt_on_error=true:print_stacktrace=true

if [[ -f "$(core_file)" ]]; then
	echo -n "There's a core dump here you might want to look at first... "
	core_file
	echo
	exit 1
fi

if [[ ! -d $coredir ]]; then
	echo "core dump directory ($coredir) does not exist, creating it."
	or_die mkdir -p "$coredir"
fi

if [[ ! -w $coredir ]]; then
	echo "core dump directory ($coredir) is not writable."
	exit 1
fi

or_die rm -f ztest.history ztest.zdb ztest.cores

ztrc=0		# ztest return value
foundcrashes=0	# number of crashes found so far
starttime=$(date +%s)
curtime=$starttime
iteration=0

# if no timeout was specified, loop forever.
while (( timeout == 0 )) || (( curtime <= (starttime + timeout) )); do
	if (( iterations > 0 )) && (( iteration++ == iterations )); then
		break
	fi

	# start each run with an empty directory
	workdir="$basedir/$rundir"
	or_die rm -rf "$workdir"
	or_die mkdir "$workdir"

	zopt="-G -VVVVV"
	# Set common working directory
	zopt="$zopt -f $workdir"

	if [[ -n "$ZTS_OBJECT_STORE" ]]; then
		# If Object Store credentials are provided configure and
		# save them.
		if credentials_in_env; then
			configure_object_store_credentials
		else
			# For running test using instance profile
			# we need to remove the underlying credentials
			# stored in the disk
			rm -f ~/.aws/credentials
			sudo rm -f /root/.aws/credentials
		fi
		case $ZTS_OBJECT_STORE in
		blob)
			# Blob storage requires no special arguments.
			;;
		s3|true)
			# Convert legacy values of 'true' to an s3 default
			ZTS_OBJECT_STORE="s3"
			zopt="$zopt -O $ZTS_OBJECT_ENDPOINT"
			zopt="$zopt -A $ZTS_REGION"
			[[ -z "$ZTS_CREDS_PROFILE" ]] && \
			    ZTS_CREDS_PROFILE="default"
			if ! is_using_iam_role; then
				zopt="$zopt -z $ZTS_CREDS_PROFILE"
			fi
			;;
		*)
			echo "Unknown object store $ZTS_OBJECT_STORE"
			exit 1
		esac
		zopt="$zopt -b $ZTS_BUCKET_NAME"
		zopt="$zopt -L $ZTS_OBJECT_STORE"
	else

		# switch between three types of configs
		# 1/3 basic, 1/3 raidz mix, and 1/3 draid mix
		choice=$((RANDOM % 3))

		# ashift range 9 - 15
		align=$(((RANDOM % 2) * 3 + 9))

		# randomly use special classes
		class="special=random"

		if [[ $choice -eq 0 ]]; then
			# basic mirror only
			parity=1
			mirrors=2
			draid_data=0
			draid_spares=0
			raid_children=0
			vdevs=2
			raid_type="raidz"
		elif [[ $choice -eq 1 ]]; then
			# fully randomized mirror/raidz (sans dRAID)
			parity=$(((RANDOM % 3) + 1))
			mirrors=$(((RANDOM % 3) * 1))
			draid_data=0
			draid_spares=0
			raid_children=$((((RANDOM % 9) + parity + 1) * (RANDOM % 2)))
			vdevs=$(((RANDOM % 3) + 3))
			raid_type="raidz"
		else
			# fully randomized dRAID (sans mirror/raidz)
			parity=$(((RANDOM % 3) + 1))
			mirrors=0
			draid_data=$(((RANDOM % 8) + 3))
			draid_spares=$(((RANDOM % 2) + parity))
			stripe=$((draid_data + parity))
			extra=$((draid_spares + (RANDOM % 4)))
			raid_children=$(((((RANDOM % 4) + 1) * stripe) + extra))
			vdevs=$((RANDOM % 3))
			raid_type="draid"
		fi

		zopt="$zopt -K $raid_type"
		zopt="$zopt -m $mirrors"
		zopt="$zopt -r $raid_children"
		zopt="$zopt -D $draid_data"
		zopt="$zopt -S $draid_spares"
		zopt="$zopt -R $parity"
		zopt="$zopt -v $vdevs"
		zopt="$zopt -a $align"
		zopt="$zopt -C $class"
		zopt="$zopt -s $size"
	fi
	cmd="$ZTEST $zopt $*"
	echo "$(date '+%m/%d %T') $cmd" | tee -a ztest.history ztest.out
	$cmd >>ztest.out 2>&1
	ztrc=$?
	grep -E '===|WARNING' ztest.out >>ztest.history

	store_core

	curtime=$(date +%s)
done

echo "zloop finished, $foundcrashes crashes found"

# restore core pattern.
case $(uname) in
Linux)
	echo "$origcorepattern" > /proc/sys/kernel/core_pattern
	;;
*)
	;;
esac

uptime >>ztest.out

if [[ $foundcrashes -gt 0 ]]; then
	exit 1
fi
