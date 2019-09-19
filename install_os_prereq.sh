#!/bin/bash

source ./common_funcs.sh

check_root

PYTHON_VERSION=$1

# check appname was supplied as argument
if [ "$PYTHON_VERSION" == "" ]; then
echo "Usage:"
echo "  $ install_os_prereq.sh [python-version]"
echo
echo "  Python version is 2 or 3 and defaults to 3 if not specified. Subversion"
echo "  of Python will be determined during runtime. The required Python version"
echo "  has to be installed and available globally."
echo
exit 1
fi

# Default python version to 3. OS has to have it installed.
if [ "$PYTHON_VERSION" == "" ]; then
PYTHON_VERSION=3
fi

if [ "$PYTHON_VERSION" != "3" -a "$PYTHON_VERSION" != "2" ]; then
error_exit "Invalid Python version specified. Acceptable values are 2 or 3 (default)"
fi

# Prerequisite standard packages. If any of these are missing,
# script will attempt to install it. If installation fails, it will abort.
if [ "$PYTHON_VERSION" == "3" ]; then
PIP="pip3"
LINUX_PREREQ=('git' 'build-essential' 'python3-dev' 'python3-pip' 'nginx' 'postgresql' 'libpq-dev' )
else
PIP="pip"
LINUX_PREREQ=('git' 'build-essential' 'python-dev' 'python-pip' 'nginx' 'postgresql' 'libpq-dev')
fi
PYTHON_PREREQ=('virtualenv' 'supervisor')

# Test prerequisites
echo "Checking if required packages are installed..."
declare -a MISSING
for pkg in "${LINUX_PREREQ[@]}"
    do
        echo "Installing '$pkg'..."
        apt-get -y install $pkg
        if [ $? -ne 0 ]; then
            echo "Error installing system package '$pkg'"
            exit 1
        fi
    done

for ppkg in "${PYTHON_PREREQ[@]}"
    do
        echo "Installing Python package '$ppkg'..."
        $PIP install $ppkg
        if [ $? -ne 0 ]; then
            echo "Error installing python package '$ppkg'"
            exit 1
        fi
    done

if [ ${#MISSING[@]} -ne 0 ]; then
    echo "Following required packages are missing, please install them first."
    echo ${MISSING[*]}
    exit 1
fi

echo "All required packages have been installed!"

