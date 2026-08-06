FROM mysql:8.0
# Pre-creates the databases used by every service on first boot.
# MYSQL_DATABASE=serms is created by the image itself; this adds the auth DB.
COPY init.sql /docker-entrypoint-initdb.d/init.sql