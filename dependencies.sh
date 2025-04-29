#!/bin/bash

# Distros that have been tested:
#   - Debian 11, 12
#   - Ubuntu 22.04, 24.04
#   - RHEL 8.10, 9.4
#   - Fedora 39, 40
#   - Rocky 9.4


declare -ar common_dependencies=(
    "wget"
    "tar"
    "git"
    "make"
    "gcc"
    "flex"
    "bison"
    "gcc-aarch64-linux-gnu"
    "cpio"
    "file"
    "rsync"
    "patch"
    "unzip"
    "bzip2"
)

declare -ar deb_dependencies=(
    "libelf-dev"
    "xz-utils"
    "g++"
    "libncurses-dev"
)

declare -ar rhel_dependencies=(
    "elfutils-libelf-devel"
    "perl"
    "xz"
    "gcc-c++"
    "ncurses-devel"
)


function __epel_repo_message() {
    echo ""
    echo "Please add the EPEL repository to your system."
    echo "The EPEL repository is needed to install the following dependencies: gcc-aarch64-linux-gnu"
    echo ""
}


function checkDependencies() {
    local running_os=$(cat /etc/os-release | grep "^ID=" | cut -d'=' -f2 | tr -d '"')
    package_manager=""

    case $running_os in
        "debian" | "ubuntu")
            dependencies=("${common_dependencies[@]}" "${deb_dependencies[@]}")
            package_manager="sudo apt install -y"
            pkgmgr() {
                dpkg -l
            }
            ;;
        "rhel" | "rocky" | "fedora")
            dependencies=("${common_dependencies[@]}" "${rhel_dependencies[@]}")
            package_manager="sudo dnf install -y"
            pkgmgr() {
                rpm -qa --qf "ii %{NAME}\n"
            }
            if [[ $running_os == "rhel" || $running_os == "rocky" ]]; then
                __epel_repo_message
            fi
            ;;
        *)
            echo "Untested OS: $running_os"
            echo "Exiting now."
            exit 1
            ;;
    esac

    missing_packages=""
    for package in "${dependencies[@]}"; do
        pkgmgr | awk '{print $2}' | cut -d':' -f1 | grep -qe "${package}"
        if [[ $? > 0 ]]; then
            missing_packages="${missing_packages} ${package}"
        fi
    done

    if [[ $missing_packages != "" ]]; then
        echo "The following dependencies are missing:${missing_packages}"
    fi
}


function installDependencies() {
    local install_dep=$1

    if [[ $install_dep != "y" && -n $missing_packages ]]; then
        echo "Exiting now, please install the packages manually or add the -i or --install-dep flag to install them automatically."
        exit 1
    fi

    if [[ -n $missing_packages ]]; then
        echo "Atempting to install missing dependencies..."
        $package_manager "${dependencies[@]}" > /dev/null 2>&1
        if [[ $? > 0 ]]; then
            echo "Failed to install dependencies, please install the packages manually. Exiting now."
            exit 1
        fi
    fi
}
