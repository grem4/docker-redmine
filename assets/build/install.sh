#!/bin/bash
set -e

GEM_CACHE_DIR="${REDMINE_BUILD_DIR}/cache"

BUILD_DEPENDENCIES="libcurl4-openssl-dev libssl-dev libmagickcore-dev libmagickwand-dev \
                    libmysqlclient-dev libpq-dev libxslt1-dev libffi-dev libyaml-dev"


exec_as_redmine() {
  sudo -HEu ${REDMINE_USER} "$@"
}


apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ${BUILD_DEPENDENCIES}


adduser --disabled-login --gecos 'Redmine' ${REDMINE_USER}
passwd -d ${REDMINE_USER}


cat > /tmp/cron.${REDMINE_USER} <<EOF
REDMINE_USER=${REDMINE_USER}
REDMINE_INSTALL_DIR=${REDMINE_INSTALL_DIR}
REDMINE_DATA_DIR=${REDMINE_DATA_DIR}
REDMINE_RUNTIME_DIR=${REDMINE_RUNTIME_DIR}
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
EOF
crontab -u ${REDMINE_USER} /tmp/cron.${REDMINE_USER}
rm -rf /tmp/cron.${REDMINE_USER}


exec_as_redmine mkdir -p ${REDMINE_INSTALL_DIR}
if [[ -f ${REDMINE_BUILD_DIR}/redmine-${REDMINE_VERSION}.tar.gz ]]; then
  exec_as_redmine tar -zvxf ${REDMINE_BUILD_DIR}/redmine-${REDMINE_VERSION}.tar.gz --strip=1 -C ${REDMINE_INSTALL_DIR}
else
  echo "Downloading Redmine ${REDMINE_VERSION}..."
  exec_as_redmine wget "http://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz" -O /tmp/redmine-${REDMINE_VERSION}.tar.gz

  echo "Extracting..."
  exec_as_redmine tar -zxf /tmp/redmine-${REDMINE_VERSION}.tar.gz --strip=1 -C ${REDMINE_INSTALL_DIR}

  exec_as_redmine rm -rf /tmp/redmine-${REDMINE_VERSION}.tar.gz
fi


PG_GEM=$(grep 'gem "pg"' ${REDMINE_INSTALL_DIR}/Gemfile | awk '{gsub(/^[ \t]+|[ \t]+$/,""); print;}')
MYSQL2_GEM=$(grep 'gem "mysql2"' ${REDMINE_INSTALL_DIR}/Gemfile | awk '{gsub(/^[ \t]+|[ \t]+$/,""); print;}')

sed -i \
  -e '/gem "pg"/d' \
  -e '/gem "mysql2"/d' \
  ${REDMINE_INSTALL_DIR}/Gemfile

(
  echo "${PG_GEM}";
  echo "${MYSQL2_GEM}";
  echo 'gem "unicorn"';
  echo 'gem "dalli", "~> 2.7.0"';
) >> ${REDMINE_INSTALL_DIR}/Gemfile


exec_as_redmine cp ${REDMINE_INSTALL_DIR}/config/database.yml.example ${REDMINE_INSTALL_DIR}/config/database.yml


cd ${REDMINE_INSTALL_DIR}


if [[ -d ${GEM_CACHE_DIR} ]]; then
  cp -a ${GEM_CACHE_DIR} ${REDMINE_INSTALL_DIR}/vendor/cache
  chown -R ${REDMINE_USER}: ${REDMINE_INSTALL_DIR}/vendor/cache
fi
exec_as_redmine bundle install -j$(nproc) --without development test --path ${REDMINE_INSTALL_DIR}/vendor/bundle


exec_as_redmine mkdir -p ${REDMINE_INSTALL_DIR}/tmp ${REDMINE_INSTALL_DIR}/tmp/pdf ${REDMINE_INSTALL_DIR}/tmp/pids ${REDMINE_INSTALL_DIR}/tmp/sockets


rm -rf ${REDMINE_INSTALL_DIR}/public/plugin_assets
exec_as_redmine ln -sf ${REDMINE_DATA_DIR}/tmp/plugin_assets ${REDMINE_INSTALL_DIR}/public/plugin_assets


rm -rf ${REDMINE_INSTALL_DIR}/tmp/thumbnails
exec_as_redmine ln -sf ${REDMINE_DATA_DIR}/tmp/thumbnails ${REDMINE_INSTALL_DIR}/tmp/thumbnails


rm -rf ${REDMINE_INSTALL_DIR}/log
exec_as_redmine ln -sf ${REDMINE_LOG_DIR}/redmine ${REDMINE_INSTALL_DIR}/log


rm -f /etc/nginx/sites-enabled/default


sed -i "s|user www-data|user ${REDMINE_USER}|" /etc/nginx/nginx.conf


sed -i "s|^logfile=.*|logfile=${REDMINE_LOG_DIR}/supervisor/supervisord.log ;|" /etc/supervisor/supervisord.conf


sed -i \
  -e "s|access_log /var/log/nginx/access.log;|access_log ${REDMINE_LOG_DIR}/nginx/access.log;|" \
  -e "s|error_log /var/log/nginx/error.log;|error_log ${REDMINE_LOG_DIR}/nginx/error.log;|" \
  /etc/nginx/nginx.conf


cat > /etc/logrotate.d/redmine <<EOF
${REDMINE_LOG_DIR}/redmine/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF


cat > /etc/logrotate.d/redmine-vhost <<EOF
${REDMINE_LOG_DIR}/nginx/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF


cat > /etc/logrotate.d/supervisord <<EOF
${REDMINE_LOG_DIR}/supervisor/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF


cat > /etc/supervisor/conf.d/nginx.conf <<EOF
[program:nginx]
priority=20
directory=/tmp
command=/usr/sbin/nginx -g "daemon off;"
user=root
autostart={{NGINX_ENABLED}}
autorestart=true
stdout_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
EOF


cat > /etc/supervisor/conf.d/unicorn.conf <<EOF
[program:unicorn]
priority=10
directory=${REDMINE_INSTALL_DIR}
environment=HOME=${REDMINE_HOME}
command=bundle exec unicorn_rails -E ${RAILS_ENV} -c ${REDMINE_INSTALL_DIR}/config/unicorn.rb
user=${REDMINE_USER}
autostart=true
autorestart=true
stopsignal=QUIT
stdout_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
EOF


cat > /etc/supervisor/conf.d/cron.conf <<EOF
[program:cron]
priority=20
directory=/tmp
command=/usr/sbin/cron -f
user=root
autostart=true
autorestart=true
stdout_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
EOF


apt-get purge -y --auto-remove ${BUILD_DEPENDENCIES}
rm -rf /var/lib/apt/lists/*
