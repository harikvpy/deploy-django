#!/bin/bash
#
# Usage:
#	$ create_django_project_run_env <appname>

source ./common_funcs.sh

check_root

# conventional values that we'll use throughout the script
APPNAME=$1
DOMAINNAME=$2
PYTHON_VERSION=$3

# check appname was supplied as argument
if [ "$APPNAME" == "" ] || [ "$DOMAINNAME" == "" ]; then
	echo "Usage:"
	echo "  $ create_django_project_run_env <project> <domain> [python-version]"
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

./install_os_prereq.sh $PYTHON_VERSION
error_exit "Error setting up OS prerequisites."

./deploy_django_project.sh $APPNAME $DOMAINNAME $PYTHON_VERSION
