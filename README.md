# deploy-django
A bash script to deploy a django project for production sites. The script sets
up the environment under which the django project can be run safely. The
environment will have the following characterstics:

* Designed to be run using Gunicorn/WSGI and as an app under NGINX
* A dedicated user/group under which the the gunicorn process will be run
* PostgreSQL database setup
* Python virtualenv setup with basic packages such as pip and django installed
* Supervisor, the python based daemon control process installed and configured
  with the necessary conf file to control the WSGI process
* An script to autostart supervisor and control it like other Ubuntu services.


