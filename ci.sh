#!/usr/bin/env bash
base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src

set -eo pipefail

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | cleanup | llvm | upload) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    do_cleanup
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets arm aarch64 x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    sudo apt-get install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        gcc \
        g++ \
        git \
        libelf-dev \
        libssl-dev \
        lld \
        make \
        ninja-build \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" fetch --depth=1 origin $branch
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['X86']}
builder.toolchain_prefix = Path('$install')

builder.build()
EOF
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)

    "$base"/build-llvm.py \
        --assertions \
        --build-target distribution \
        --check-targets clang lld llvm \
        --install-folder "$install" \
        --install-target distribution \
        --projects clang lld \
        --quiet-cmake \
        --shallow-clone \
        --show-build-commands \
        --vendor-string "KCUF" \
        --targets ARM AArch64 X86 \
        --lto thin \
        --defines LLVM_PARALLEL_COMPILE_JOBS=$(nproc) LLVM_PARALLEL_LINK_JOBS=$(nproc) CMAKE_C_FLAGS=-O3 CMAKE_CXX_FLAGS=-O3 \
        "${extra_args[@]}"
}

function do_cleanup() {
    # Remove unused products
    rm -fr $install/include
    rm -f $install/lib/*.a $install/lib/*.la

    # Strip remaining products
    for f in $(find $install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
        strip "${f::-1}"
    done

    # Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
    for bin in $(find $install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
        # Remove last character from file output (':')
        bin="${bin::-1}"

        echo "$bin"
        patchelf --set-rpath "$ORIGIN/../lib" "$bin"
    done
}

function do_upload() {
    git config --global user.name "Anand Shekhawat"
    git config --global user.email "anandsingh215@yahoo.com"
    ssh-keyscan -t rsa -p 22 -H gitlab.com 2>&1 | tee -a ~/.ssh/known_hosts

    rel_date="$(date "+%Y%m%d")" # ISO 8601 format
    builder_commit="$(git rev-parse HEAD)"
    pushd $src/llvm-project
    llvm_commit="$(git rev-parse HEAD)"
    popd
    llvm_commit_url="https://github.com/llvm/llvm-project/commit/$llvm_commit"
    binutils_ver="$(ls $src | grep "^binutils-" | sed "s/binutils-//g" | head -1)"
    rm -rf rel_repo
    git clone git@gitlab.com:shekhawat2/clang-builds.git $base/rel_repo

    pushd $base/rel_repo
    rm -rf ./*
    cp -r ../install/* .
    git add .
    git commit -am "Update to $rel_date build

    LLVM commit: $llvm_commit_url
    binutils version: $binutils_ver
    Builder commit: https://github.com/shekhawat2/tc-build/commit/$builder_commit"
    git push
    popd
}

parse_parameters "${@}"
do_"${action:=all}"
