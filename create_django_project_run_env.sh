#!/bin/bash
#
# Usage:
#	$ create_django_project_run_env <appname>

# error exit function
function error_exit
{
    echo "$1" 1>&2
    exit 1
}

# check if we're being run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

# conventional values that we'll use throughout the script
APPNAME=$1
DOMAINNAME=$2
GROUPNAME=webapps
# app folder name under /webapps/<appname>_project
APPFOLDER=$1_project
APPFOLDERPATH=/$GROUPNAME/$APPFOLDER
# prerequisite standard packages. If any of these are missing, 
# script will attempt to install it. If installation fails, it will abort.
LINUX_PREREQ=('git' 'build-essential' 'python-dev' 'nginx' 'postgresql' 'libpq-dev' 'python-pip')
PYTHON_PREREQ=('virtualenv' 'supervisor')

# check appname was supplied as argument
if [ "$APPNAME" == "" ] || [ "$DOMAINNAME" == "" ]; then
    echo "Usage:"
    echo "  $ create_django_project_run_env <project> <domain>"
    echo
    exit 1
fi

# test prerequisites
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
        pip install $ppkg
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

echo "All required packages are installed!"

# create the app folder 
echo "Creating app folder '$APPFOLDERPATH'..."
mkdir -p /$GROUPNAME/$APPFOLDER || error_exit "Could not create app folder"

# test the group 'webapps' exists, and if it doesn't create it
getent group $GROUPNAME
if [ $? -ne 0 ]; then
    echo "Creating group '$GROUPNAME' for automation accounts..."
    groupadd --system $GROUPNAME || error_exit "Could not create group 'webapps'"
fi

# create the app user account, same name as the appname
grep "$APPNAME:" /etc/passwd
if [ $? -ne 0 ]; then
    echo "Creating automation user account '$APPNAME'..."
    useradd --system --gid $GROUPNAME --shell /bin/bash --home $APPFOLDERPATH $APPNAME || error_exit "Could not create automation user account '$APPNAME'"
fi

# change ownership of the app folder to the newly created user account
echo "Setting ownership of $APPFOLDERPATH and its descendents to $APPNAME:$GROUPNAME..."
chown -R $APPNAME:$GROUPNAME $APPFOLDERPATH || error_exit "Error setting ownership"
# give group execution rights in the folder;
# TODO: is this necessary? why?
chmod g+x $APPFOLDERPATH || error_exit "Error setting group execute flag"

# install python virtualenv in the APPFOLDER
su -l $APPNAME << 'EOF'
pwd
echo "Setting up python virtualenv..."
virtualenv . || error_exit "Error installing virtual environment to app folder"
source ./bin/activate
# upgrade pip
pip install --upgrade pip || error_exist "Error upgrading pip to the latest version"
# install prerequisite python packages for a django app using pip
echo "Installing base python packages for the app..."
# Standard django packages which will be installed. If any of these fail, script will abort
DJANGO_PKGS=('django' 'psycopg2' 'gunicorn' 'setproctitle')
for dpkg in "${DJANGO_PKGS[@]}"
    do
        echo "Installing $dpkg..."
        pip install $dpkg || error_exit "Error installing $dpkg"
    done
# create the default folders where we store django app's resources
echo "Creating static file folders..."
mkdir logs run ssl static media || error_exit "Error creating static folders"
EOF

echo "Creating gunicorn startup script..."
cat > /tmp/gunicorn_start.sh << EOF
#!/bin/bash
# Makes the following assumptions:
#
#  1. All applications are located in a subfolder within /webapps
#  2. Each app gets a dedicated subfolder <appname> under /webapps. This will
#     be referred to as the app folder.
#  3. The group account 'webapps' exists and each app is to be executed
#     under the user account <appname>.
#  4. The app folder and all its recursive contents are owned by 
#     <appname>:webapps.
#  5. The django app is stored under /webapps/<appname>/<appname> folder.
#

NAME="$APPNAME"                                  # Name of the application
DJANGODIR=$APPFOLDERPATH/\$NAME             # Django project directory
SOCKFILE=$APPFOLDERPATH/run/gunicorn.sock  # we will communicte using this unix socket
USER=$APPNAME                                        # the user to run as
GROUP=$GROUPNAME                                     # the group to run as
NUM_WORKERS=3                                     # how many worker processes should Gunicorn spawn
DJANGO_SETTINGS_MODULE=$APPNAME.settings             # which settings file should Django use
DJANGO_WSGI_MODULE=$APPNAME.wsgi                     # WSGI module name

echo "Starting $APPNAME as \`whoami\`"

# Activate the virtual environment
cd \$DJANGODIR
source ../bin/activate
export DJANGO_SETTINGS_MODULE=\$DJANGO_SETTINGS_MODULE
export PYTHONPATH=\$DJANGODIR:\$PYTHONPATH

# Create the run directory if it doesn't exist
RUNDIR=\$(dirname \$SOCKFILE)
test -d \$RUNDIR || mkdir -p \$RUNDIR

# Start your Django Unicorn
# Programs meant to be run under supervisor should not daemonize themselves (do not use --daemon)
exec ../bin/gunicorn \${DJANGO_WSGI_MODULE}:application \
  --name \$NAME \
  --workers \$NUM_WORKERS \
  --user=\$USER --group=\$GROUP \
  --bind=unix:\$SOCKFILE \
  --log-level=debug \
  --log-file=-
EOF
# move the script to app folder
mv /tmp/gunicorn_start.sh $APPFOLDERPATH
chown $APPNAME:$GROUPNAME $APPFOLDERPATH/gunicorn_start.sh
chmod u+x $APPFOLDERPATH/gunicorn_start.sh

# create the PostgreSQL database and associated role for the app
# Database and role name would be the same as the <appname> argument
echo "Creating secure password for database role..."
DBPASSWORD=`openssl rand -base64 32`
if [ $? -ne 0 ]; then
    error_exit "Error creating secure password for database role."
fi
echo $DBPASSWORD > $APPFOLDERPATH/db_passwd.txt
chown $APPNAME:$GROUPNAME $APPFOLDERPATH/db_passwd.txt
echo "Creating PostgreSQL role '$APPNAME'..."
su postgres -c "createuser -S -D -R -w $APPNAME"
echo "Changing password of database role..."
su postgres -c "psql -c \"ALTER USER $APPNAME WITH PASSWORD '$DBPASSWORD';\""
echo "Creating PostgreSQL database '$APPNAME'..."
su postgres -c "createdb --owner $APPNAME $APPNAME"

# create nginx template in /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-available
APPSERVERNAME=$APPNAME
APPSERVERNAME+=_gunicorn
cat > /etc/nginx/sites-available/$APPNAME.conf << EOF
upstream $APPSERVERNAME {
    server unix:$APPFOLDERPATH/run/gunicorn.sock fail_timeout=0;
}
server {
    listen 80;
    server_name $DOMAINNAME;

    client_max_body_size 5M;
    keepalive_timeout 5;
    underscores_in_headers on;

    access_log $APPFOLDERPATH/logs/nginx-access.log;
    error_log $APPFOLDERPATH/logs/nginx-error.log;

    location /media  {
        alias $APPFOLDERPATH/media;
    }
    location /static {
        alias $APPFOLDERPATH/static;
    }
    location /static/admin {
       alias $APPFOLDERPATH/lib/python2.7/site-packages/django/contrib/admin/static/admin/;
    }
    # This would redirect http site access to HTTPS. Uncomment to enable
    #location / {
    #    rewrite ^ https://\$http_host\$request_uri? permanent;
    #}
    # To make the site pure HTTPS, comment the following section while 
    # uncommenting the above section. Also uncoment the HTTPS section
    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$http_host;
        proxy_redirect off;
        proxy_pass http://$APPSERVERNAME;
    }
}

# Uncomment this if you want to enable HTTPS access. Also, remember to install 
# the site certificate, either purcahased or generated.
#server {
#    listen 443 default ssl;
#    server_name $DOMAINNAME;
#
#    client_max_body_size 5M;
#    keepalive_timeout 5;
#
#    ssl_certificate /etc/nginx/ssl/cert_chain.crt;
#    ssl_certificate_key $APPFOLDERPATH/ssl/$DOMAINNAME.key;
#
#    access_log $APPFOLDERPATH/logs/nginx-access.log;
#    error_log $APPFOLDERPATH/logs/nginx-error.log;
#
#    location /media  {
#        alias $APPFOLDERPATH/media;
#    }
#    location /static {
#        alias $APPFOLDERPATH/static;
#    }
#    location /static/admin {
#       alias $APPFOLDERPATH/lib/python2.7/site-packages/django/contrib/admin/static/admin/;
#    }
#    location / {
#        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#        proxy_set_header Host \$http_host;
#        proxy_set_header X-Forwarded-Proto \$scheme;
#        proxy_redirect off;
#        proxy_pass http://$APPSERVERNAME;
#    }
#}
EOF
# make a symbolic link to the nginx conf file in sites-enabled
ln -s /etc/nginx/sites-available/$APPNAME.conf /etc/nginx/sites-enabled/$APPNAME 

# create supervisord.conf
cat > /etc/supervisord.conf << EOF
[unix_http_server]
file=/tmp/supervisor.sock   ; (the path to the socket file)

[supervisord]
logfile=/tmp/supervisord.log ; (main log file;default $CWD/supervisord.log)
logfile_maxbytes=50MB        ; (max main logfile bytes b4 rotation;default 50MB)
logfile_backups=10           ; (num of main logfile rotation backups;default 10)
loglevel=info                ; (log level;default info; others: debug,warn,trace)
pidfile=/tmp/supervisord.pid ; (supervisord pidfile;default supervisord.pid)
nodaemon=false               ; (start in foreground if true;default false)
minfds=1024                  ; (min. avail startup file descriptors;default 1024)
minprocs=200                 ; (min. avail process descriptors;default 200)

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock ; use a unix:// URL  for a unix socket

[include]
files = /etc/supervisor/*.conf
EOF

# create the supervisor application conf file
mkdir -p /etc/supervisor
cat > /etc/supervisor/$APPNAME.conf << EOF
[program:$APPNAME]
command = $APPFOLDERPATH/gunicorn_start.sh
user = $APPNAME
stdout_logfile = $APPFOLDERPATH/logs/gunicorn_supervisor.log
redirect_stderr = true
EOF

# create supervisord init.d script that can be controlled with service
echo "Setting up supervisor to autostart during bootup..."
cat > /etc/init.d/supervisord << EOF
#! /bin/sh
### BEGIN INIT INFO
# Provides:          supervisord
# Required-Start:    \$remote_fs
# Required-Stop:     \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Example initscript
# Description:       This file should be used to construct scripts to be
#                    placed in /etc/init.d.
### END INIT INFO

# Author: Dan MacKinlay <danielm@phm.gov.au>
# Based on instructions by Bertrand Mathieu
# http://zebert.blogspot.com/2009/05/installing-django-solr-varnish-and.html

# Do NOT "set -e"

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="Description of the service"
NAME=supervisord
DAEMON=/usr/local/bin/supervisord
DAEMON_ARGS=""
PIDFILE=/var/run/\$NAME.pid
SCRIPTNAME=/etc/init.d/\$NAME

# Exit if the package is not installed
[ -x "\$DAEMON" ] || exit 0

# Read configuration variable file if it is present
[ -r /etc/default/\$NAME ] && . /etc/default/\$NAME

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.0-6) to ensure that this file is present.
. /lib/lsb/init-functions

#
# Function that starts the daemon/service
#
do_start()
{
	# Return
	#   0 if daemon has been started
	#   1 if daemon was already running
	#   2 if daemon could not be started
	start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON --test > /dev/null \
		|| return 1
	start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON -- \
		\$DAEMON_ARGS \
		|| return 2
	# Add code here, if necessary, that waits for the process to be ready
	# to handle requests from services started subsequently which depend
	# on this one.  As a last resort, sleep for some time.
}

#
# Function that stops the daemon/service
#
do_stop()
{
	# Return
	#   0 if daemon has been stopped
	#   1 if daemon was already stopped
	#   2 if daemon could not be stopped
	#   other if a failure occurred
	start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 --pidfile \$PIDFILE --name \$NAME
	RETVAL="$?"
	[ "\$RETVAL" = 2 ] && return 2
	# Wait for children to finish too if this is a daemon that forks
	# and if the daemon is only ever run from this initscript.
	# If the above conditions are not satisfied then add some other code
	# that waits for the process to drop all resources that could be
	# needed by services started subsequently.  A last resort is to
	# sleep for some time.
	start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --exec \$DAEMON
	[ "$?" = 2 ] && return 2
	# Many daemons don't delete their pidfiles when they exit.
	rm -f \$PIDFILE
	return "\$RETVAL"
}

#
# Function that sends a SIGHUP to the daemon/service
#
do_reload() {
	#
	# If the daemon can reload its configuration without
	# restarting (for example, when it is sent a SIGHUP),
	# then implement that here.
	#
	start-stop-daemon --stop --signal 1 --quiet --pidfile \$PIDFILE --name \$NAME
	return 0
}

case "$1" in
  start)
	[ "\$VERBOSE" != no ] && log_daemon_msg "Starting \$DESC" "\$NAME"
	do_start
	case "$?" in
		0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  stop)
	[ "\$VERBOSE" != no ] && log_daemon_msg "Stopping \$DESC" "\$NAME"
	do_stop
	case "$?" in
		0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  #reload|force-reload)
	#
	# If do_reload() is not implemented then leave this commented out
	# and leave 'force-reload' as an alias for 'restart'.
	#
	#log_daemon_msg "Reloading \$DESC" "\$NAME"
	#do_reload
	#log_end_msg $?
	#;;
  restart|force-reload)
	#
	# If the "reload" option is implemented then remove the
	# 'force-reload' alias
	#
	log_daemon_msg "Restarting \$DESC" "\$NAME"
	do_stop
	case "$?" in
	  0|1)
		do_start
		case "$?" in
			0) log_end_msg 0 ;;
			1) log_end_msg 1 ;; # Old process is still running
			*) log_end_msg 1 ;; # Failed to start
		esac
		;;
	  *)
	  	# Failed to stop
		log_end_msg 1
		;;
	esac
	;;
  *)
	#echo "Usage: \$SCRIPTNAME {start|stop|restart|reload|force-reload}" >&2
	echo "Usage: \$SCRIPTNAME {start|stop|restart|force-reload}" >&2
	exit 3
	;;
esac

:
EOF

# enable execute flag on the script
chmod +x /etc/init.d/supervisord || error_exit "Error setting execute flag on supervisord"

# create the entries in runlevel folders to autostart supervisord
update-rc.d supervisord defaults || error_exit "Error configuring supervisord to autostart"

# now create a quasi django project that can be run using a GUnicorn script
echo "Installing quasi django project..."
su -l $APPNAME << EOF
source ./bin/activate
django-admin.py startproject $APPNAME
EOF

echo "Done!"
