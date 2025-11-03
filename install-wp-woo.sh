#!/usr/bin/env bash
set -euo pipefail

# Defaults (override via flags)
SITE_DOMAIN="${SITE_DOMAIN:-store.local.lan}"
SITE_URL="${SITE_URL:-http://store.local.lan}"
SITE_TITLE="${SITE_TITLE:-Lunara Shop}"
ADMIN_USER="${ADMIN_USER:-amber}"
ADMIN_PASS="${ADMIN_PASS:-ChangeMe_Strong!}"
ADMIN_EMAIL="${ADMIN_EMAIL:-amber@example.com}"

DB_NAME="${DB_NAME:-wpdb}"
DB_USER="${DB_USER:-wpuser}"
DB_PASS="${DB_PASS:-ChangeMe_DBStrong!}"

TIMEZONE="${TIMEZONE:-America/New_York}"
WEBROOT="${WEBROOT:-/var/www/wordpress}"
PHP_V="${PHP_V:-8.2}"

# --- simple flag parser (e.g., --site-url http://x) ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-domain)   SITE_DOMAIN="$2"; shift 2;;
    --site-url)      SITE_URL="$2"; shift 2;;
    --site-title)    SITE_TITLE="$2"; shift 2;;
    --admin-user)    ADMIN_USER="$2"; shift 2;;
    --admin-pass)    ADMIN_PASS="$2"; shift 2;;
    --admin-email)   ADMIN_EMAIL="$2"; shift 2;;
    --db-name)       DB_NAME="$2"; shift 2;;
    --db-user)       DB_USER="$2"; shift 2;;
    --db-pass)       DB_PASS="$2"; shift 2;;
    --timezone)      TIMEZONE="$2"; shift 2;;
    --webroot)       WEBROOT="$2"; shift 2;;
    --php)           PHP_V="$2"; shift 2;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

export DEBIAN_FRONTEND=noninteractive

echo "[1/9] Installing packages"
apt update
apt -y install nginx mariadb-server mariadb-client \
  "php${PHP_V}-fpm" "php${PHP_V}-cli" "php${PHP_V}-common" "php${PHP_V}-mysql" \
  "php${PHP_V}-xml" "php${PHP_V}-curl" "php${PHP_V}-zip" "php${PHP_V}-gd" \
  "php${PHP_V}-mbstring" "php${PHP_V}-intl" php-imagick \
  curl unzip ca-certificates

echo "[2/9] PHP-FPM tuning"
PHP_INI="/etc/php/${PHP_V}/fpm/php.ini"
sed -i 's/^;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/' "$PHP_INI" || true
sed -i "s|^;date.timezone =.*|date.timezone = ${TIMEZONE}|" "$PHP_INI"
systemctl enable --now "php${PHP_V}-fpm"

echo "[3/9] Database setup"
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "[4/9] Nginx vhost"
mkdir -p "${WEBROOT}"
cat >/etc/nginx/sites-available/wordpress.conf <<NGINX
server {
    listen 80;
    server_name ${SITE_DOMAIN};
    root ${WEBROOT};

    index index.php index.html;
    client_max_body_size 64m;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_V}-fpm.sock;
    }

    location ~* \.(log|sql|bak|ini|sh)\$ { deny all; }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/wordpress.conf
nginx -t
systemctl reload nginx
systemctl enable --now nginx

echo "[5/9] WP-CLI"
curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
chmod +x /usr/local/bin/wp

echo "[6/9] WordPress core"
cd /tmp
wp core download --path="${WEBROOT}" --allow-root
cd "${WEBROOT}"
chown -R www-data:www-data "${WEBROOT}"

echo "[7/9] Configure & install WP"
wp config create \
  --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASS}" \
  --dbhost="localhost" --dbprefix="wp_" --skip-check --allow-root

wp config set DISALLOW_FILE_EDIT true --type=constant --allow-root
wp config set WP_POST_REVISIONS 5 --type=constant --raw --allow-root
wp config set WP_MEMORY_LIMIT '128M' --type=constant --allow-root
wp config set WP_DEBUG false --type=constant --raw --allow-root

wp core install \
  --url="${SITE_URL}" \
  --title="${SITE_TITLE}" \
  --admin_user="${ADMIN_USER}" \
  --admin_password="${ADMIN_PASS}" \
  --admin_email="${ADMIN_EMAIL}" \
  --skip-email \
  --allow-root

wp option update timezone_string "${TIMEZONE}" --allow-root
wp option update blog_public 0 --allow-root
wp option update users_can_register 0 --allow-root

wp rewrite structure '/%postname%/' --hard --allow-root
wp rewrite flush --hard --allow-root

echo "[8/9] WooCommerce + minimal theme + cleanup"
wp plugin install woocommerce --activate --allow-root
wp theme install astra --activate --allow-root

# Remove default posts/pages/comments if present
wp post delete $(wp post list --post_type='post' --format=ids --allow-root) --force --allow-root || true
wp post delete $(wp post list --post_type='page' --format=ids --allow-root) --force --allow-root || true
wp comment delete $(wp comment list --format=ids --allow-root) --force --allow-root || true

# Create Woo pages if missing
wp wc tool run install_pages --allow-root || true

echo "[9/9] Ownership + cron"
chown -R www-data:www-data "${WEBROOT}"

# Real cron every 5 minutes
if ! grep -q "wp cron event run" <(crontab -l 2>/dev/null || true); then
  ( crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/wp --path=${WEBROOT} cron event run --due-now --allow-root >/dev/null 2>&1" ) | crontab -
fi

cat <<INFO

======================================================
 WordPress + WooCommerce installed!

 URL:      ${SITE_URL}
 Admin:    ${SITE_URL}/wp-admin
 User:     ${ADMIN_USER}
 Pass:     ${ADMIN_PASS}

 Registration disabled; permalinks on; Astra active;
 demo content removed.

 If using a raw IP instead of ${SITE_DOMAIN}, make sure
 SITE_URL matched it. You can change it later with:
   wp option update siteurl "http://IP" --allow-root
   wp option update home "http://IP" --allow-root
======================================================
INFO