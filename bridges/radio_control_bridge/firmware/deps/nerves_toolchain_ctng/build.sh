#!/usr/bin/env bash

# Example
#
# build.sh /path/to/defconfig /path/to/build/dir

set -e

# Set CTNG_USE_GIT=true to use git to download the release (only needed for non-released ct-ng builds)

CTNG_USE_GIT=true
CTNG_TAG=daf19e17615fdc58503ead8ebff252d7ade90fc0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

BASE_CONFIG=$1
WORK_DIR=$2

if [[ -z $BASE_CONFIG ]] || [[ -z $WORK_DIR ]]; then
    echo "build.sh <defconfig> <work directory>"
    exit 1
fi

ARTIFACT_NAME=$(basename "$WORK_DIR")

READLINK=readlink
BUILD_ARCH=$(uname -m)
BUILD_OS=$(uname -s | awk '{print tolower($0)}')
if [[ $BUILD_OS = "cygwin_nt-6.1" ]]; then
    # A simple cygwin looks better.
    BUILD_OS="cygwin"
elif [[ $BUILD_OS = "darwin" ]]; then
    # Homebrew has a different prefix depending on x86_64 or arm64
    HOMEBREW_PREFIX="$(brew --prefix)"

    # Make sure that we use GNU readlink on OSX
    READLINK=greadlink
fi

if [[ -z $HOST_ARCH ]]; then
    HOST_ARCH=$BUILD_ARCH
fi
if [[ -z $HOST_OS ]]; then
    HOST_OS=$BUILD_OS
fi

echo "Using HOST_ARCH: $HOST_ARCH"
echo "Using HOST_OS: $HOST_OS"
echo "Using BUILD_OS: $BUILD_OS"

if [[ ! -e $BASE_CONFIG ]]; then
    echo "Can't find $BASE_CONFIG. Check that it exists."
    echo
    echo "Here are some options:"
    for dir in $(ls $BASE_DIR); do
        if [[ -f $dir/defconfig ]]; then
            echo $dir
        fi
    done
    exit 1
fi

# Ensure that the config and work paths are absolute
BASE_CONFIG=$($READLINK -f "$BASE_CONFIG")
WORK_DIR=$($READLINK -f "$WORK_DIR")

CTNG_CONFIG_DIR=$(dirname "$BASE_CONFIG")
# Append host-specific modifications to the base defconfig
HOST_CONFIG=$CTNG_CONFIG_DIR/${HOST_OS}_${HOST_ARCH}_defconfig
if [[ ! -e $HOST_CONFIG ]]; then
    HOST_CONFIG=$SCRIPT_DIR/defaults/${HOST_OS}_${HOST_ARCH}_defconfig
    if [[ ! -e $HOST_CONFIG ]]; then
        echo "Can't find a ${HOST_OS}_${HOST_ARCH}_defconfig fragment. Check that one exists."
        exit 1
    fi
fi

DL_DIR=$HOME/.nerves/dl

if [[ ! -e $CTNG_CONFIG_DIR/VERSION ]]; then
    echo "Can't find $CTNG_CONFIG_DIR/VERSION. Check that it exists."
    exit 1
fi

NERVES_TOOLCHAIN_VERSION=$(cat "$CTNG_CONFIG_DIR/VERSION" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# Programs used for building the toolchain, but not for distributing (e.g. ct-ng)
LOCAL_INSTALL_DIR=$WORK_DIR/usr

# Install directories for the tools we make
GCC_INSTALL_DIR=$WORK_DIR/x-tools  # make sure that this is the same as in the config file

# Bump the number of open files. ct-ng does this now so this can be deleted when we're
# happy with it. (Probably the next time someone looks at these lines of code.)
n_open_files=$(ulimit -n)
if [ "${n_open_files}" -lt 2048 ]; then
     echo "Number of open files ${n_open_files} may not be sufficient to build the toolchain; increasing to 2048"
     ulimit -n 2048
fi

if [[ "$CI" = "true" ]]; then
    # CircleCI runs out of memory if too many concurrent builds go at once
    CTNG_BUILD=build.4
else
    CTNG_BUILD=build
fi

if [[ $BUILD_OS = "darwin" ]]; then
    # Mac-specific updates

    # Use GNU tar from Homebrew (brew install gnu-tar)
    TAR=gtar

    WORK_DMG=$WORK_DIR.dmg
    WORK_DMG_VOLNAME=$ARTIFACT_NAME

    export CURSES_LIBS="-L$(brew --prefix ncurses)/lib -lncursesw"
    CROSSTOOL_LDFLAGS="-L$HOMEBREW_PREFIX/lib -lintl"
    CROSSTOOL_CFLAGS="-I$HOMEBREW_PREFIX/include"

    # Apple provides an old version of Bison that will fail about 20 minutes into the build.
    export PATH="$(brew --prefix bison)/bin:$PATH"
    BISON="$(brew --prefix bison)/bin/bison"
    if [[ ! -e "$BISON" ]]; then
        echo "Building gcc requires a more recent version on bison than Apple provides. Install with 'brew install bison'"
        echo "Expecting to find bison at '$BISON'."
        exit 1
    fi

    export PATH="$(brew --prefix m4)/bin:$PATH"
    M4="$(brew --prefix m4)/bin/m4"
    if [[ ! -e "$M4" ]]; then
        echo "Building gcc requires a more recent version on m4 than Apple provides. Install with 'brew install m4'"
        echo "Expecting to find m4 at '$M4'."
        exit 1
    fi

    # Pull in GNU grep
    export PATH="$(brew --prefix grep)/libexec/gnubin:$PATH"
    GREP="$(brew --prefix grep)/libexec/gnubin/grep"
    if [[ ! -e "$GREP" ]]; then
        echo "Building gcc requires GNU grep. Install with 'brew install grep'"
        echo "Expecting to find grep at '$GREP'."
        exit 1
    fi

elif [[ $BUILD_OS = "linux" ]]; then
    # Linux-specific updates
    TAR=tar

    # Long path lengths cause gcc builds to fail. This is due to argument
    # length exceeded errors from long Make commandlines. To work around this
    # issue, we tell crosstool-ng to do its work under /tmp/ctng-work. This
    # forces one build at a time.
    CT_WORK_DIR="/tmp/ctng-work"
elif [[ $BUILD_OS = "cygwin" || $BUILD_OS = "freebsd" ]]; then
    # Windows-specific updates
    TAR=tar

    # For crosstool-ng
    export AWK=gawk
else
    echo "unknown host OS: $BUILD_OS"
    exit 1
fi

init()
{
    # Clean up an old build and create the work directory
    if [[ $BUILD_OS = "darwin" ]]; then
        hdiutil detach "/Volumes/$WORK_DMG_VOLNAME" 2>/dev/null || true
        rm -fr "$WORK_DIR" "$WORK_DMG"
        hdiutil create -size 32g -fs "Case-sensitive HFS+" -volname "$WORK_DMG_VOLNAME" "$WORK_DMG"
        hdiutil attach "$WORK_DMG"
        ln -s "/Volumes/$WORK_DMG_VOLNAME" "$WORK_DIR"
    elif [[ $BUILD_OS = "linux" || $BUILD_OS = "cygwin" || $BUILD_OS = "freebsd" ]]; then
        if [[ -e $WORK_DIR ]]; then
            chmod -R u+w "$WORK_DIR"
            rm -fr "$WORK_DIR"
        fi
        if [[ -e "$CT_WORK_DIR" ]]; then
            chmod -R u+w "$CT_WORK_DIR"
            rm -fr "$CT_WORK_DIR"
        fi
        mkdir -p "$WORK_DIR"
    fi

    mkdir -p "$GCC_INSTALL_DIR"
    mkdir -p "$DL_DIR"
}

gcc_tuple()
{
    # Figure out the target's tuple. It's the name of the only directory.
    # Don't call this until after build_gcc()
    tuplepath=$(ls "$GCC_INSTALL_DIR")
    if [[ -e $tuplepath ]]; then
        echo "unknown"
    else
        basename "$tuplepath"
    fi
}

gcc_tuple_underscores()
{
    gcc_tuple | tr - _
}

build_gcc()
{
    # Build and install ct-ng to the work directory
    cd "$WORK_DIR"
    ln -sf "$DL_DIR" dl
    rm -fr crosstool-ng

    CTNG_TAR_XZ=crosstool-ng-$CTNG_TAG.tar.xz
    if [[ ! -e $DL_DIR/$CTNG_TAR_XZ ]]; then
        if [[ $CTNG_USE_GIT = "true" ]]; then
            git clone https://github.com/crosstool-ng/crosstool-ng.git
            cd crosstool-ng
            git checkout $CTNG_TAG
            cd ..
            $TAR -c -J --exclude=.git -f "$DL_DIR/$CTNG_TAR_XZ" crosstool-ng
        else
            curl -L -o "$DL_DIR/$CTNG_TAR_XZ" http://crosstool-ng.org/download/crosstool-ng/$CTNG_TAR_XZ
            $TAR xf "$DL_DIR/$CTNG_TAR_XZ"
        fi
    else
        $TAR xf "$DL_DIR/$CTNG_TAR_XZ"
    fi

    # Apply patches
    "$SCRIPT_DIR/scripts/apply-patches.sh" crosstool-ng "$SCRIPT_DIR/patches/crosstool-ng"

    cd crosstool-ng
    if [[ $CTNG_USE_GIT = "true" ]]; then
        ./bootstrap
    fi
    if [[  $BUILD_OS = "freebsd" ]]; then
        SED=/usr/local/bin/gsed
	SED=/usr/local/bin/gsed MAKE=/usr/local/bin/gmake PATCH=/usr/local/bin/gpatch ./configure --prefix="$LOCAL_INSTALL_DIR"
	gmake
	gmake install
    elif [[ $BUILD_OS = "darwin" ]]; then
        # Homebrew's gcc is gcc-13
        BINUTILS=$(brew --prefix binutils)
        CC=gcc-13 CXX=g++-13 OBJDUMP=$BINUTILS/bin/gobjdump OBJCOPY=$BINUTILS/bin/gobjcopy READELF=$BINUTILS/bin/greadelf \
	    CFLAGS="$CROSSTOOL_CFLAGS" LDFLAGS="$CROSSTOOL_LDFLAGS" SED=$HOMEBREW_PREFIX/bin/gsed MAKE=$HOMEBREW_PREFIX/bin/gmake ./configure --prefix="$LOCAL_INSTALL_DIR"
        SED=$HOMEBREW_PREFIX/bin/gsed
	gmake
	gmake install
    else
        SED=sed
	./configure --prefix="$LOCAL_INSTALL_DIR"
	make
	make install
    fi

    # Check for ct-ng
    if [[ ! -e $LOCAL_INSTALL_DIR/bin/ct-ng ]]; then
        echo "ct-ng build failed."
        exit 1
    fi

    # Setup the toolchain build directory
    mkdir -p "$WORK_DIR/build"
    cd "$WORK_DIR/build"
    CTNG_CONFIG=$PWD/defconfig
    cat "$BASE_CONFIG" "$HOST_CONFIG" > "$CTNG_CONFIG"

    CTNG=$LOCAL_INSTALL_DIR/bin/ct-ng

    # Process the configuration
    $CTNG defconfig

    # Save the defconfig back for later review
    cp "$CTNG_CONFIG" "$CTNG_CONFIG.orig"
    $CTNG savedefconfig

    echo "Original defconfig"
    cat "$CTNG_CONFIG.orig"
    echo "Resaved defconfig"
    cat "$CTNG_CONFIG"

    # Check the defconfig didn't change or lose entries
    "$SCRIPT_DIR/scripts/unmerge_defconfig.exs" "$BASE_CONFIG" "$HOST_CONFIG" "$CTNG_CONFIG"

    # Build the toolchain
    if [[ -z $CTNG_CC ]]; then
        PREFIX=""
    else
        PREFIX="CC=$CTNG_CC CXX=$CTNG_CXX"
    fi

    # Configure logging when on CI (see crosstool-ng's build script)
    if [[ "$CI" = "true" ]]; then
      echo "Modifying logging for CI"
      $SED -i -e 's/^.*\(CT_LOG_ERROR\).*$/# \1 is not set/' \
        -e 's/^.*\(CT_LOG_WARN\).*$/# \1 is not set/' \
        -e 's/^.*\(CT_LOG_INFO\).*$/# \1 is not set/' \
        -e 's/^.*\(CT_LOG_EXTRA\).*$/\1=y/' \
        -e 's/^.*\(CT_LOG_ALL\).*$/# \1 is not set/' \
        -e 's/^.*\(CT_LOG_DEBUG\).*$/# \1 is not set/' \
        -e 's/^.*\(CT_LOG_LEVEL_MAX\).*$/\1="EXTRA"/' \
        -e 's/^.*\(CT_LOG_PROGRESS_BAR\).*$/# \1 is not set/' \
        -e 's/^.*\(CT_LOCAL_TARBALLS_DIR\).*$/\1="${HOME}\/src"/' \
        -e 's/^.*\(CT_SAVE_TARBALLS\).*$/\1=y/' \
        "$WORK_DIR/build/.config"
    fi

    # Start building and print dots to keep CI from killing the build due
    # to console inactivity.
    $PREFIX "$CTNG" $CTNG_BUILD &
    local build_pid=$!
    {
        while ps -p $build_pid >/dev/null; do
           sleep 12
           printf "."
        done
    } &
    local keepalive_pid=$!

    # Wait for the build to finish
    wait $build_pid 2>/dev/null

    # Stop the keepalive task
    kill $keepalive_pid
    wait $keepalive_pid 2>/dev/null || true

    TARGET_TUPLE=$(gcc_tuple)

    echo "Fixing permissions on release"
    # ct-ng likes to mark everything read-only which seems reasonable, but it
    # can be really annoying when trying to cleanup a toolchain.
    chmod -R u+w "$GCC_INSTALL_DIR/$TARGET_TUPLE"

    # Clean up the build product
    rm -f "$GCC_INSTALL_DIR/$TARGET_TUPLE/build.log.bz2"

    # Clean up crosstool-ng's work directory if we put it in a global location
    if [[ "$CI" = "true" ]]; then
        echo "Not cleaning up work directory since CI build"
    else
        if [[ -e "$CT_WORK_DIR" ]]; then
            chmod -R u+w "$CT_WORK_DIR"
            rm -fr "$CT_WORK_DIR"
        fi
    fi
}

toolchain_base_name()
{
    # Compute the base filename part of the build product
    echo "nerves_toolchain_$(gcc_tuple_underscores)-$NERVES_TOOLCHAIN_VERSION.$HOST_OS-$HOST_ARCH"
}

save_build_info()
{
    # Save useful information if we ever need to reproduce the toolchain
    TARGET_TUPLE=$(gcc_tuple)
    echo "$NERVES_TOOLCHAIN_VERSION" > "$GCC_INSTALL_DIR/$TARGET_TUPLE/nerves-toolchain.tag"
    cp "$CTNG_CONFIG" "$GCC_INSTALL_DIR/$TARGET_TUPLE/ct-ng.defconfig"
    cp "$WORK_DIR/build/.config" "$GCC_INSTALL_DIR/$TARGET_TUPLE/ct-ng.config"
}

fix_kernel_case_conflicts()
{
    # On Macs, the file system is case-preserving, but case-insensitive. The netfilter
    # module in the Linux kernel provides header files that differ only in case, so this
    # won't work if you need to use both the capitalized and lowercase versions of the
    # header files.
    #
    # The workaround is to remove case conflicts in the kernel include
    # directory so that users don't need to use case sensitive filesystems on
    # OSX.
    TARGET_TUPLE=$(gcc_tuple)
    LINUX_INCLUDE_DIR=$GCC_INSTALL_DIR/$TARGET_TUPLE/$TARGET_TUPLE/sysroot/usr/include/linux
    rm -f "$LINUX_INCLUDE_DIR/netfilter/xt_CONNMARK.h" \
          "$LINUX_INCLUDE_DIR/netfilter/xt_DSCP.h" \
          "$LINUX_INCLUDE_DIR/netfilter/xt_MARK.h" \
          "$LINUX_INCLUDE_DIR/netfilter/xt_RATEEST.h" \
          "$LINUX_INCLUDE_DIR/netfilter/xt_TCPMSS.h" \
          "$LINUX_INCLUDE_DIR/netfilter_ipv4/ipt_ECN.h" \
          "$LINUX_INCLUDE_DIR/netfilter_ipv4/ipt_TTL.h" \
          "$LINUX_INCLUDE_DIR/netfilter_ipv6/ip6t_HL.h"
}

finalize_products()
{
    echo "Beginning of finalize_products"
    save_build_info

    if [[ $BUILD_OS = "darwin" ]]; then
        # Prune out filenames with case conflicts and before make a tarball
        fix_kernel_case_conflicts
    elif [[ $HOST_OS = "linux" || $HOST_OS = "freebsd" ]]; then
        # Linux and FreeBSD don't have the case issues
        echo ""
    else
        # Windows is case insensitive by default, so fix the conflicts
        fix_kernel_case_conflicts
    fi
}

init
build_gcc
finalize_products
echo "Done making toolchain in $GCC_INSTALL_DIR."
