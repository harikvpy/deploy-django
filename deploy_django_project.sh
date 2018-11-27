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

GROUPNAME=webapps
# app folder name under /webapps/<appname>_project
APPFOLDER=$1_project
APPFOLDERPATH=/$GROUPNAME/$APPFOLDER

# Determine requested Python version & subversion
if [ "$PYTHON_VERSION" == "3" ]; then
	PYTHON_VERSION_STR=`python3 -c 'import sys; ver = "{0}.{1}".format(sys.version_info[:][0], sys.version_info[:][1]); print(ver)'`
else
	PYTHON_VERSION_STR=`python -c 'import sys; ver = "{0}.{1}".format(sys.version_info[:][0], sys.version_info[:][1]); print ver'`
fi

# Verify required python version is installed
echo "Python version: $PYTHON_VERSION_STR"

# ###################################################################
# Create the app folder 
# ###################################################################
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
echo "Creating environment setup for django app..."
if [ "$PYTHON_VERSION" == "3" ]; then
su -l $APPNAME << 'EOF'
pwd
echo "Setting up python virtualenv..."
virtualenv -p python3 . || error_exit "Error installing Python 3 virtual environment to app folder"

EOF
else
su -l $APPNAME << 'EOF'
pwd
echo "Setting up python virtualenv..."
virtualenv . || error_exit "Error installing Python 2 virtual environment to app folder"

EOF
fi

# ###################################################################
# In the new app specific virtual environment:
# 	1. Upgrade pip
#	2. Install django in it.
#	3. Create following folders:-
#		static -- Django static files (to be collected here)
#		media  -- Django media files
#		logs   -- nginx, gunicorn & supervisord logs
#		nginx  -- nginx configuration for this domain
#		ssl	   -- SSL certificates for the domain(NA if LetsEncrypt is used)
# ###################################################################
su -l $APPNAME << 'EOF'
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
# Create the UNIX socket file for WSGI interface
echo "Creating WSGI interface UNIX socket file..."
python -c "import socket as s; sock = s.socket(s.AF_UNIX); sock.bind('./run/gunicorn.sock')"

EOF

# ###################################################################
# Generate Django production secret key
# ###################################################################
echo "Generating Django secret key..."
DJANGO_SECRET_KEY=`openssl rand -base64 48`
if [ $? -ne 0 ]; then
    error_exit "Error creating secret key."
fi
echo $DJANGO_SECRET_KEY > $APPFOLDERPATH/.django_secret_key
chown $APPNAME:$GROUPNAME $APPFOLDERPATH/.django_secret_key

# ###################################################################
# Create the script that will init the virtual environment. This
# script will be called from the gunicorn start script created next.
# ###################################################################
echo "Creating virtual environment setup script..."
cat > /tmp/prepare_env.sh << EOF
DJANGODIR=$APPFOLDERPATH/$APPNAME          # Django project directory
DJANGO_SETTINGS_MODULE=$APPNAME.settings # settings file for the app

export DJANGO_SETTINGS_MODULE=\$DJANGO_SETTINGS_MODULE
export PYTHONPATH=\$DJANGODIR:\$PYTHONPATH
export SECRET_KEY=`cat $APPFOLDERPATH/.django_secret_key`

cd $APPFOLDERPATH
source ./bin/activate
EOF
mv /tmp/prepare_env.sh $APPFOLDERPATH
chown $APPNAME:$GROUPNAME $APPFOLDERPATH/prepare_env.sh

# ###################################################################
# Create gunicorn start script which will be spawned and managed
# using supervisord.
# ###################################################################
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

cd $APPFOLDERPATH
source ./prepare_env.sh

SOCKFILE=$APPFOLDERPATH/run/gunicorn.sock  # we will communicte using this unix socket
USER=$APPNAME                                        # the user to run as
GROUP=$GROUPNAME                                     # the group to run as
NUM_WORKERS=3                                     # how many worker processes should Gunicorn spawn
DJANGO_WSGI_MODULE=$APPNAME.wsgi                     # WSGI module name

echo "Starting $APPNAME as \`whoami\`"

# Create the run directory if it doesn't exist
RUNDIR=\$(dirname \$SOCKFILE)
test -d \$RUNDIR || mkdir -p \$RUNDIR

# Start your Django Unicorn
# Programs meant to be run under supervisor should not daemonize themselves (do not use --daemon)
exec ./bin/gunicorn \${DJANGO_WSGI_MODULE}:application \
  --name $APPNAME \
  --workers \$NUM_WORKERS \
  --user=\$USER --group=\$GROUP \
  --bind=unix:\$SOCKFILE \
  --log-level=debug \
  --log-file=-
EOF

# Move the script to app folder
mv /tmp/gunicorn_start.sh $APPFOLDERPATH
chown $APPNAME:$GROUPNAME $APPFOLDERPATH/gunicorn_start.sh
chmod u+x $APPFOLDERPATH/gunicorn_start.sh

# ###################################################################
# Create the PostgreSQL database and associated role for the app
# Database and role name would be the same as the <appname> argument
# ###################################################################
echo "Creating secure password for database role..."
DBPASSWORD=`openssl rand -base64 32`
if [ $? -ne 0 ]; then
    error_exit "Error creating secure password for database role."
fi
echo $DBPASSWORD > $APPFOLDERPATH/.django_db_password
chown $APPNAME:$GROUPNAME $APPFOLDERPATH/.django_db_password
export DB_PASSWORD=`cat $APPFOLDERPATH/.django_db_password`
echo "Creating PostgreSQL role '$APPNAME'..."
su postgres -c "createuser -S -D -R -w $APPNAME"
echo "Changing password of database role..."
su postgres -c "psql -c \"ALTER USER $APPNAME WITH PASSWORD '$DBPASSWORD';\""
echo "Creating PostgreSQL database '$APPNAME'..."
su postgres -c "createdb --owner $APPNAME $APPNAME"

# ###################################################################
# Create nginx template in /etc/nginx/sites-available
# ###################################################################
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
       alias $APPFOLDERPATH/lib/python$PYTHON_VERSION_STR/site-packages/django/contrib/admin/static/admin/;
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
#       alias $APPFOLDERPATH/lib/python$PYTHON_VERSION_STR/site-packages/django/contrib/admin/static/admin/;
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

# ###################################################################
# Setup supervisor
# ###################################################################

# Copy supervisord.conf if it does not exist
if [ ! -f /etc/supervisord.conf ]; then
	cp ./supervisord.conf /etc || error_exit "Error copying supervisord.conf"
fi

# Create the supervisor application conf file
mkdir -p /etc/supervisor
cat > /etc/supervisor/$APPNAME.conf << EOF
[program:$APPNAME]
command = $APPFOLDERPATH/gunicorn_start.sh
user = $APPNAME
stdout_logfile = $APPFOLDERPATH/logs/gunicorn_supervisor.log
redirect_stderr = true
EOF

SUPERVISORD_ACTION='reload'
# Create supervisord init.d script that can be controlled with service
if [ ! -f /etc/init.d/supervisord ]; then
    echo "Setting up supervisor to autostart during bootup..."
	cp ./supervisord /etc/init.d || error_exit "Error copying /etc/init.d/supervisord"
	# enable execute flag on the script
	chmod +x /etc/init.d/supervisord || error_exit "Error setting execute flag on supervisord"
	# create the entries in runlevel folders to autostart supervisord
	update-rc.d supervisord defaults || error_exit "Error configuring supervisord to autostart"
    SUPERVISORD_ACTION='start'
fi

# Now create a quasi django project that can be run using a GUnicorn script
echo "Installing quasi django project..."
su -l $APPNAME << EOF
source ./bin/activate
django-admin.py startproject $APPNAME
EOF

# ###################################################################
# Reload/start supervisord and nginx
# ###################################################################
# Start/reload the supervisord daemon
service supervisord status > /dev/null
if [ $? -eq 0 ]; then
    # Service is running, restart it
    service supervisord restart || error_exit "Error restarting supervisord"
else
    # Service is not running, probably it's been installed first. Start it 
    service supervisord start || error_exit "Error starting supervisord"
fi

# Reload nginx so that requests to domain are redirected to the gunicorn process
nginx -s reload || error_exit "Error reloading nginx. Check configuration files"

echo "Done!"
