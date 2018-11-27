# To be sourced from the other modules

# Exits the script with a message and exit code 1
function error_exit
{
    echo "$1" 1>&2
    exit 1
}

# check if we're being run as root
function check_root
{
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit
    fi
}
