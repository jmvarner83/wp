#!/usr/bin/env bash
# ───────────────────────────────────────────────
# Minimal WordPress + WooCommerce Auto Installer
# For clean Debian 12 LXC in Proxmox
# ───────────────────────────────────────────────

set -e
export DEBIAN_FRONTEND=noninteractive

WP_ROOT="/var/www/wordpress"
PHP_SOCK="/run/php/php8.2-fpm.sock"

echo "──────────────────────────────"
echo " Updating & preparing base system"
echo "──────────────────────────────"
apt update && apt upgrade -y
apt install -y nginx mariadb-server mariadb-client php php-fpm \
  php-mysql php-curl php-gd php-xml php-mbstring php-zip php-intl php-bcmath php-cli curl unzip git jq

systemctl enable --now nginx php8.2-fpm mariadb

echo "──────────────────────────────"
echo " Configuring MariaDB"
echo "──────────────────────────────"
mysql -uroot <<'SQL'
CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wpuser'@'localhost' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "──────────────────────────────"
echo " Installing wp-cli"
echo "──────────────────────────────"
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp

echo "──────────────────────────────"
echo " Installing WordPress"
echo "──────────────────────────────"
rm -rf "$WP_ROOT"
mkdir -p "$WP_ROOT"
cd "$WP_ROOT"

wp core download --allow-root

wp config create --allow-root \
  --dbname=wordpress --dbuser=wpuser --dbpass=password --dbhost=localhost \
  --skip-check --extra-php <<'PHP'
define('FS_METHOD', 'direct');
define('WP_DEBUG', true);
PHP

IP_ADDR=$(hostname -I | awk '{print $1}')

wp core install --allow-root \
  --url="http://$IP_ADDR" \
  --title="Woo Demo" \
  --admin_user=admin --admin_password=admin --admin_email=none@none.com

echo "──────────────────────────────"
echo " Setting up Nginx site"
echo "──────────────────────────────"
cat >/etc/nginx/sites-available/wordpress.conf <<NGINX
server {
    listen 80 default_server;
    server_name $IP_ADDR _;
    root $WP_ROOT;

    index index.php index.html;
    client_max_body_size 64m;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/wordpress.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "──────────────────────────────"
echo " Installing WooCommerce & Astra"
echo "──────────────────────────────"
wp plugin install woocommerce --activate --allow-root
wp theme install astra --activate --allow-root

echo "──────────────────────────────"
echo " Debloating WordPress"
echo "──────────────────────────────"
wp plugin delete hello akismet --allow-root
wp theme delete twentytwentyfour twentytwentythree twentytwentytwo --allow-root
wp option update woocommerce_force_ssl_checkout no --allow-root
wp rewrite structure '/%postname%/' --hard --allow-root
wp rewrite flush --hard --allow-root

echo "──────────────────────────────"
echo " Creating test auth.php file"
echo "──────────────────────────────"
cat >$WP_ROOT/auth.php <<'PHP'
<?php
header('Content-Type: text/plain');
echo isset($_SERVER['HTTP_AUTHORIZATION'])
     ? "AUTH: " . $_SERVER['HTTP_AUTHORIZATION']
     : "NO AUTH HEADER";
PHP
chown -R www-data:www-data $WP_ROOT

echo "──────────────────────────────"
echo " Setup complete!"
echo "──────────────────────────────"
echo " Visit: http://$IP_ADDR/"
echo " Admin: http://$IP_ADDR/wp-admin (admin / admin)"
echo " Test REST: curl -i http://$IP_ADDR/wp-json/"
echo "──────────────────────────────"
