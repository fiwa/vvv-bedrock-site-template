#!/usr/bin/env bash

set -eo pipefail

echo " * Custom site template provisioner ${VVV_SITE_NAME}"

# fetch the first host as the primary domain. If none is available, generate a default using the site name
DB_NAME=$(get_config_value 'db_name' "${VVV_SITE_NAME}")
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*]/}
DB_PREFIX=$(get_config_value 'db_prefix' 'wp_')
DOMAIN=$(get_primary_host "${VVV_SITE_NAME}".test)
PUBLIC_DIR=$(get_config_value 'public_dir' "public_html")
SITE_TITLE=$(get_config_value 'site_title' "${DOMAIN}")
WP_LOCALE=$(get_config_value 'locale' 'en_US')
WP_TYPE=$(get_config_value 'wp_type' "single")
WP_VERSION=$(get_config_value 'wp_version' 'latest')

PUBLIC_DIR_PATH="${VVV_PATH_TO_SITE}"
if [ ! -z "${PUBLIC_DIR}" ]; then
  PUBLIC_DIR_PATH="${PUBLIC_DIR_PATH}/${PUBLIC_DIR}"
fi

# Make a database, if we don't already have one
setup_database() {
  echo -e " * Creating database '${DB_NAME}' (if it's not already there)"
  mysql -u root --password=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`"
  echo -e " * Granting the wp user priviledges to the '${DB_NAME}' database"
  mysql -u root --password=root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO wp@localhost IDENTIFIED BY 'wp';"
  echo -e " * DB operations done."
}

setup_nginx_folders() {
  echo " * Setting up the log subfolder for Nginx logs"
  noroot mkdir -p "${VVV_PATH_TO_SITE}/log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-error.log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-access.log"
  echo " * Creating the public folder at '${PUBLIC_DIR}' if it doesn't exist already"
  noroot mkdir -p "${PUBLIC_DIR_PATH}"
}

copy_nginx_configs() {
  echo " * Copying the sites Nginx config template"
  if [ -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" ]; then
    echo " * A vvv-nginx-custom.conf file was found"
    noroot cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    echo " * Using the default vvv-nginx-default.conf, to customize, create a vvv-nginx-custom.conf"
    noroot cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-default.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi

  echo " * Applying public dir setting to Nginx config"
  noroot sed -i "s#{vvv_public_dir}#/${PUBLIC_DIR}#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"

  LIVE_URL=$(get_config_value 'live_url' '')
  if [ ! -z "$LIVE_URL" ]; then
    echo " * Adding support for Live URL redirects to NGINX of the website's media"
    # replace potential protocols, and remove trailing slashes
    LIVE_URL=$(echo "${LIVE_URL}" | sed 's|https://||' | sed 's|http://||'  | sed 's:/*$::')

    redirect_config=$((cat <<END_HEREDOC
if (!-e \$request_filename) {
  rewrite ^/[_0-9a-zA-Z-]+(/app/uploads/.*) \$1;
}
if (!-e \$request_filename) {
  rewrite ^/app/uploads/(.*)\$ \$scheme://${LIVE_URL}/app/uploads/\$1 redirect;
}
END_HEREDOC

    ) |
    # pipe and escape new lines of the HEREDOC for usage in sed
    sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n\\1/g'
    )

    noroot sed -i -e "s|\(.*\){{LIVE_URL}}|\1${redirect_config}|" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    noroot sed -i "s#{{LIVE_URL}}##" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi
}

install_bedrock() {
  if [ ! -d "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/web/wp" ]; then
    if [ ! -d "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/web" ]; then
      echo " * Install fresh Bedrock"
      noroot composer create-project roots/bedrock "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}"
    else
      echo " * Install Bedrock depencencies"
      cd "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}"
      noroot composer install
    fi
    initial_env
  fi
}

initial_env() {
  if [[ ! -f "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/.env" ]]; then
    echo " * Creating .env"
    noroot cp "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/.env.example" "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/.env"
  fi
  echo " * Setting up .env"
  noroot sed -i "s/DB_NAME='database_name'/DB_NAME='${DB_NAME}'/g" "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/.env"
  noroot sed -i "s/DB_USER='database_user'/DB_USER='wp'/g" "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/.env"
  noroot sed -i "s/DB_PASSWORD='database_password'/DB_PASSWORD='wp'/g" "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/.env"
  noroot sed -i "s/WP_HOME='http:\/\/example.com'/WP_HOME='https:\/\/${DOMAIN}'/g" "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}/.env"
}

install_wp() {
  cd "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}"
  if ! $(noroot wp core is-installed ); then
    echo " * WordPress is present but isn't installed to the database"
    echo " * Installing WordPress"
    ADMIN_USER=$(get_config_value 'admin_user' "admin")
    ADMIN_PASSWORD=$(get_config_value 'admin_password' "password")
    ADMIN_EMAIL=$(get_config_value 'admin_email' "admin@local.test")

    echo " * Installing using wp core install --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\""
    cd "${VVV_PATH_TO_SITE}/${PUBLIC_DIR}"
    noroot wp core install --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
    echo " * WordPress was installed, with the username '${ADMIN_USER}', and the password '${ADMIN_PASSWORD}' at '${ADMIN_EMAIL}'"
  fi
}

cd "${VVV_PATH_TO_SITE}"

setup_database
setup_nginx_folders
copy_nginx_configs
install_bedrock
install_wp

echo " * Bedrock Site Template provisioner script completed for ${VVV_SITE_NAME}"
