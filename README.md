# deploy-django
A bash script to deploy a django project for production sites. The script sets
up the environment under which the django project can be run safely. The
environment will have the following characterstics:

* Designed to be run using Gunicorn/WSGI and as an app under NGINX.
* A dedicated user/group under which the the gunicorn process will be run.
* A new PostgreSQL database with the same name as the project specified
  in command line. 
* Python virtualenv setup with basic packages such as pip and django installed.
* Supervisor, the python based daemon control process installed and configured
  with the necessary conf file to control the WSGI process.
* An script to autostart supervisor and control it like other Ubuntu services.

# Usage
Use the command as follows:
```
create_django_project_run_env <project> <domain>
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

For example, for deploying the domain qqden.com, use the following command:

```
create_django_project_run_env qqden qqden.com
```
