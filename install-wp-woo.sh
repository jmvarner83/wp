#!/usr/bin/env bash
# Minimal WordPress + WooCommerce one-shot installer for Debian 12 LXC
# - Self-fixes CRLF (needs to be run with: bash install-wp-woo.sh)
# - Installs Nginx, PHP-FPM, MariaDB, WordPress, WooCommerce, Astra
# - Debloats WP, sets permalinks, forwards Authorization header
# - Adds /auth.php header test; runs sanity checks; retries once if needed

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------- Config (edit if you like) ----------
WP_DB_NAME="wordpress"
WP_DB_USER="wpuser"
WP_DB_PASS="password"

WP_ADMIN_USER="admin"
WP_ADMIN_PASS="admin"
WP_ADMIN_EMAIL="none@none.com"

WP_TITLE="Woo Demo"
WP_ROOT="/var/www/wordpress"
CLIENT_MAX_BODY="64m"
# ----------------------------------------------

ME="$(readlink -f "$0")"
RETRIED="${RETRIED:-0}"

# --- 0) Self-heal CRLF (works only if invoked via bash, not shebang) ---
if grep -q $'\r' "$ME"; then
  echo "[*] CRLF detected in $ME — normalizing to LF and re-executing once..."
  tmp="$(mktemp)"
  sed 's/\r$//' "$ME" > "$tmp"
  install -m 0755 "$tmp" "$ME"
  rm -f "$tmp"
  if [[ "$RETRIED" != "1" ]]; then
    export RETRIED=1
    exec bash "$ME" "$@"
  fi
fi

# --- 1) Helper funcs ---
log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
fail() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

ip_addr() { hostname -I | awk '{print $1}'; }
detect_php_sock() {
  local sock
  sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -z "$sock" ]] && fail "No PHP-FPM sock found in /run/php/. Is php-fpm installed?"
  echo "$sock"
}

# --- 2) Update & install base packages ---
log "Updating system & installing packages"
apt update && apt upgrade -y
apt install -y nginx mariadb-server mariadb-client curl unzip git jq \
  php php-fpm php-mysql php-curl php-gd php-xml php-mbstring php-zip php-intl php-bcmath php-cli

systemctl enable --now nginx
systemctl enable --now mariadb

# --- 3) Database setup ---
log "Configuring MariaDB (DB=$WP_DB_NAME, user=$WP_DB_USER)"
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$WP_DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASS';
GRANT ALL PRIVILEGES ON \`$WP_DB_NAME\`.* TO '$WP_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

# --- 4) wp-cli ---
if ! command -v wp >/dev/null 2>&1; then
  log "Installing wp-cli"
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
fi

# --- 5) WordPress core ---
IP="$(ip_addr)"
log "Installing WordPress into $WP_ROOT (URL: http://$IP)"
rm -rf "$WP_ROOT"
mkdir -p "$WP_ROOT"
cd "$WP_ROOT"
wp core download --allow-root

wp config create --allow-root \
  --dbname="$WP_DB_NAME" --dbuser="$WP_DB_USER" --dbpass="$WP_DB_PASS" --dbhost=localhost \
  --skip-check --extra-php <<'PHP'
define('FS_METHOD', 'direct');
define('WP_DEBUG', true);
PHP

wp core install --allow-root \
  --url="http://$IP" \
  --title="$WP_TITLE" \
  --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" --admin_email="$WP_ADMIN_EMAIL"

# --- 6) Nginx vhost ---
PHP_SOCK="$(detect_php_sock)"
log "Creating Nginx vhost (default_server), PHP sock: $PHP_SOCK"
cat >/etc/nginx/sites-available/wordpress.conf <<NGINX
server {
    listen 80 default_server;
    server_name $IP _;
    root $WP_ROOT;

    index index.php index.html;
    client_max_body_size $CLIENT_MAX_BODY;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
        # Make Woo REST Basic Auth work:
        fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
    }

    location ~* \.(log|sql|bak|ini|sh)\$ { deny all; }
}
NGINX

ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/wordpress.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# --- 7) WooCommerce + Astra + debloat ---
log "Installing WooCommerce + Astra and debloating"
wp plugin install woocommerce --activate --allow-root
wp theme install astra --activate --allow-root

# Remove extras
wp plugin delete hello akismet --allow-root || true
wp theme delete twentytwentyfour twentytwentythree twentytwentytwo --allow-root || true

# Tweak basics
wp option update woocommerce_force_ssl_checkout no --allow-root
wp rewrite structure '/%postname%/' --hard --allow-root
wp rewrite flush --hard --allow-root

# --- 8) auth header test endpoint ---
log "Adding /auth.php header test"
cat >"$WP_ROOT/auth.php" <<'PHP'
<?php
header('Content-Type:text/plain; charset=UTF-8');
echo isset($_SERVER['HTTP_AUTHORIZATION']) ? "AUTH: ".$_SERVER['HTTP_AUTHORIZATION'] : "NO AUTH HEADER";
PHP

chown -R www-data:www-data "$WP_ROOT"

# --- 9) Sanity tests ---
log "Running sanity tests"
set +e
CODE_JSON=$(curl -s -o /dev/null -w "%{http_code}" "http://$IP/wp-json/")
CODE_AUTH=$(curl -s -o /dev/null -w "%{http_code}" "http://$IP/auth.php")
AUTH_ECHO=$(curl -s -H "Authorization: Basic dGVzdDp0ZXN0" "http://$IP/auth.php")
set -e

echo "REST /wp-json status: $CODE_JSON"
echo "/auth.php status:     $CODE_AUTH"
echo "/auth.php with header: $AUTH_ECHO"

NEEDS_RETRY=0
if [[ "$CODE_JSON" != "200" ]]; then
  echo "[warn] /wp-json/ not 200 (got $CODE_JSON)"
  NEEDS_RETRY=1
fi
if [[ "$CODE_AUTH" != "200" ]]; then
  echo "[warn] /auth.php not 200 (got $CODE_AUTH)"
  NEEDS_RETRY=1
fi
if ! grep -q "AUTH: Basic dGVzdDp0ZXN0" <<< "$AUTH_ECHO"; then
  echo "[warn] Authorization header not seen at /auth.php"
  NEEDS_RETRY=1
fi

if [[ "$NEEDS_RETRY" -eq 1 && "$RETRIED" != "1" ]]; then
  echo "[*] Attempting one auto-fix & retry…"
  # Re-detect PHP sock (in case version changed during apt upgrade)
  PHP_SOCK="$(detect_php_sock)"
  sed -i "s#fastcgi_pass unix:.*#fastcgi_pass unix:$PHP_SOCK;#g" /etc/nginx/sites-available/wordpress.conf
  nginx -t && systemctl reload nginx
  export RETRIED=1
  exec bash "$ME" "$@"
fi

[[ "$NEEDS_RETRY" -eq 1 ]] && fail "Sanity checks still failing after one retry."

# --- 10) Success info ---
log "All set! Visit:"
echo "  Site:      http://$IP/"
echo "  Admin:     http://$IP/wp-admin  (user: $WP_ADMIN_USER  pass: $WP_ADMIN_PASS)"
echo "  REST:      curl -i http://$IP/wp-json/"
echo "  Auth test: curl -i -H 'Authorization: Basic dGVzdDp0ZXN0' http://$IP/auth.php"

echo
echo "Next: In WP Admin → WooCommerce → Settings → Advanced → REST API → Add key"
echo "      (Owner: Administrator, Permissions: Read/Write)"
echo
echo "Then test:"
echo "  curl -i -u ck_xxx:cs_xxx http://$IP/wp-json/wc/v3/products"
