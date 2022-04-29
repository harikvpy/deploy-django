[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/harikvpy)

# deploy-django
A bash script to deploy a django project for production sites. The script sets
up the environment under which the django project can be run safely. The
environment will have the following characterstics:

* Designed to be run using Gunicorn/WSGI and as an app under NGINX.
* Each site will be run in a dedicated automation user account sandbox.
* A new PostgreSQL database with the same name as the project specified
  in command line that can be used by Django.
* Python virtualenv setup with basic packages such as pip and django installed.
* Supervisor, the python based daemon control process installed and
  configured with the necessary conf file to control the WSGI process.
* An script to autostart supervisor and control it like other Ubuntu services.

# Usage
The primary end-user facing components of the package are the two scripts:-

* `install_os_prereq.sh`
* `deploy_django_project.sh`

The names ought to be self explanatory.

In any case, the first script ensures that the necessary packages are installed
in the OS. Run this first when deploying a django project to a fresh Ubuntu
image.

The second script creates the automation account, virtual environment,
PostgreSQL DB & and sets up the assortment of scripts that make up the website
deployment.

`install_os_prereq.sh` needs to be run only once per machine, typically after
a fresh OS image installation. Thereafter `deploy_django_project.sh` can be run
as many times as necessary, once for each domain that you want to support on
the same machine (using HTTP virtual hosts).

> The old command `create_django_project_run_env.sh` is essentially a wrapper
> that calls the above two scripts in sequence. Unless you have a specific
> reason (I can't think of any), it's best that you don't use this script at
> all. Instead use the new scripts `install_os_prereq.sh` and
> `deploy_django_project.sh`.

Use the commands as follows:
```
install_os_prereq.sh [<python-version>]
deploy_django_project.sh <project> <domain> [<python-version>]
```
where:

`<project>` is the name of the parent project you use to refer to the
solution. This should be a single word without space or other special charactes.
A new user account with this name will be created under group `webapps` and
the django project will be served from this account's home folder
`/webapps/<project>_project`. If group `webapps` does not exist, it will
be created.

`<domain>` is the domain name where the website is to be to be deployed.
Specify this without the `www` prefix. Appropriate NGINX configuration files
will be generated to direct requets to both `<domain>` and
`www.<domain>` to the django app.

`<python-version>` is either `2` or `3`, which is the python version that you
wish to use for the project. In most cases this can be omitted as it defaults
to `3`.

For example, for deploying the domain example.com, use the following command:

```
$ install_os_prereq.sh
$ deploy_django_project.sh example example.com
```
Note that in both the above commands the default Python version of `3` is used.

This will create a new user account `example` under group `webapps` with home
folder set to `/webapps/example_project/`. Under this folder, it will create a
python virtual environment and a gunicorn startup script, that will be auto
started using the Supervisor process control system. Ngix configuration will be
updated such that requests to domain example.com (and wwww.example.com) will be
proxied to this gunicon WSGI instance. A placeholder Django app, aptly named
`<project>` will also be created under the home folder which will serve as the
the WSGI endpoint.

# Background
A production Django app is deployed using the WSGI proxy mechanism which
serves requests proxied from an HTTP server such as NGINX or Apache. Here the
HTTP server does little more than forwarding the incoming requests to the
configured WSGI backend application server and forward the received response
from the appserver to the client. The HTTP server will be configured such
that for specific domain name(s), a specific WSGI app server instance will be
used. For Django apps, the recommended HTTP server and WSGI app servers are
NGINX and Gunicorn respectively.

Since deploying a production web app involves multiple components and each of
them with their own configuration, it's imperative that all these varied steps
are either documented or captured in the form of script files such that these
can be replicated across multiple server instances. Even for the most simple
web application that uses a single server instance, a production site requires
a staging server where the code needs to be deployed and tested for runtime
and deployment issues before launching it live. And for sites expecting medium
to heavy traffic and load, the code would have be deployed on multiple servers
with the HTTP server deployed as a load balancer or a dedicated load balancer
distributing the HTTP request load equally across multiple application servers.
Therefore the need for consistent configuration of multiple servers cannot be
overemphasized.

An even better solution would be standardizing the deployment characteristics
of a Django web application such that multiple Django applications, serving
multiple sites, all are deployed in a certain fixed configuration. This would
make troubleshooting and subsequent fixing of any deployment issues easy as
all sites retain the same characteristics.

This script is an attempt to achieve this deployment standardization for all
Django apps.

# Assumptions

* Script is written to work with Ubuntu Linux 14.04, though it should work fine
  on Ubuntu versions >= 12.04. Script does install the prerequisite Linux
  packages if they are not installed and therefore a vanilla OS installation
  is all that is necessary.
* PostgreSQL is used as the database backend. PostgreSQL is considered the best
  DB backend for Django apps and provides more sophisticated RDBMS features than
  MySQL.
* As already mentioned HTTP server is provided by NGNIX and WSGI is served by
  Gunicorn. NGINX and Gunicorn are considered the best match for Django apps.
* Supervisor process control system is managed to Gunicorn appserver processes.
  Using supervisor provides automatic restart of the Gunicorn appserver daemon,
  should it crash for some reason, making the overall deployment that much more
  robust.
* The app server is served using python runtime from a dedicated virtual
  environment and therefore the system-wide python distribution is not touched.

# Details
The sequence of steps taken by the script can be summed up as:
## OS Packages
As part of the installation, the following OS packages are installed:
* git
* build-essential
* nginx
* postgresql
* libpq-dev
* python-dev|python3-dev
* python-pip|python3-pip

Note that the package `python-pip` & `python3-pip` is a python package, though
it is installed from the OS package distribution mechanism.

After successful completion of the above, necessary global python packages
are installed. These are:
* virtualenv
* supervisor
These are installed using Python Package Installer, which itself installed in
the previous step(through `python-pip`).

## User/Group
A dedicated user account is created for the app server. This helps isolate
the app server's run environment from other normal user accounts which are
typically used to login to the machine to do management tasks. This is an
automation account and disabled for interactive login. This user account name
defaults the `<project>` argument of the command line and is made a member of
group `webapps`. If this group does not exist, it will be created.

Home folder for this account will be set to `/webapps/<project>_project`.

## Runtime environment
Post user/group creation, the runtime evironment for the app is created. First
the python virtual environment is created. This is created in the home folder
of the dedicated automation user account. Therefore `python` and related
binaries will be installed to `~/bin` folder and python packages will be
installed at `~/local/lib/python2.x` or `~/local/lib/python3.x`.

The following packages will be installed to the dedicated python virtual
environment just created:

* django
* psycopg2
* gunicorn
* setproctitle

## Runtime scripts
The script then generates two bash scripts that will be used to start the app
server. The script is split into two files such that it can be used for
interactive shell for manual interaction with the Django app server. These
scripts are:
* prepare_env.sh
* gunicorn_start.sh

The former is an environment script and is to be sourced from the interactive
shell whereas the latter is the master script that is used to the start Gunicorn
app server (Supervisor will be configured to start the app server through this
script).

So if manual interaction with the production site is desired, one may sudo into
the `<project>` user account and source it as:

```
$ sudo -u <project> -i
$ source ./prepare_env.sh
```

## Database
A PostgreSQL database, with the same name as `<project>` will be created for
use by the Django app. A dedicated PostgreSQL role with the same name will
also be created. This role is configured with a random password and this
password is stored in `~/.django_db_password`.

## Nginx Configuration
A Nginx conf file for the requested domain will be created in
`/etc/nginx/sites-available` and it will be enabled by creating the necessary
soft link in `/etc/nginx/sites-enabled`. This configuration will be setup such
all requests to the domain (specified in the command line argument) will be
proxied to the Gunicorn server started through the script created earlier.

## Setup supervisor
Supervisor installation does not create its own configuration file,
`/etc/supervisord.conf`. Also Supervisor installation does not create the
necessary `init.d` script to start it automatically and manage it interactively.
This script addresses both by creating the necessary files for this --
`/etc/supervisord.conf` and `/etc/init.d/supervisord`, a script to manage it
using the Ubuntu standard `service <daemon> {start|stop}` commands.

The script will also create `/etc/supervisor/<project>/conf` file which will
contain the configuration for the Gunicorn app server.

## Placeholder Django app
A placeholder Django app will be created in
`/webapps/<project>_project/<project>`. This placeholder app can be replaced
with the real production code.

## Other Details
### Django secret key
Django applications generated using its admin command, will put the secret key
in the generated settings file. Since the Django source is shared between
different developers and since the code is typically stored in an online
repository, this key gets shared across different machines and usere. Therefore
production sites should not use this embedded key and instead should use its
own key. To automate this the script will generate a random string which is
stored in `~/.django_secret_key`.

### Environment variables
Both the secret key and the database role password (stored in
`~/.django_secret_key` and `~/.django_db_password`) is made available to
the Django app through the environment variables `SECRET_KEY` and
`DB_PASSWORD` respectively. These variables will be set through the script
`~/prepare_env.sh`.

Additionally, the settings file to be used with the Django app is set
through the environment variable `DJANGO_SETTINGS_MODULE`.

Providing these three environment variables, allows the Django app to use
different values for these three Django app parameters in production
environment than what is used in development.

# Notes
The script, `~/gunicorn_start.sh` is the only connection between the Gunicorn
configuration and the Django app server. So as long as running this script
results in a valid app server instance, the rest of the system will remain
of the expected integrity. So if the Django app being deployed requires
different configuration, any requisite changes can be made from this file.

`~/prepare_env.sh` is sourced from this file to setup the environment. So this
file is also available for further tweaking to suit the deployed app's
runtime environment.
