#!/usr/bin/env bash
# Guacamole 1.6.0 fresh install on Ubuntu 24.04
# - RDP (freerdp3-dev), SSH, VNC via guacd (built from source)
# - Tomcat 10.1.44 (manual), OpenJDK 21
# - MariaDB + JDBC auth (MySQL Connector/J)
# - TOTP, QuickConnect, Session Recording
# - Jakarta migration for Tomcat 10
# - Nginx (optional) with Let's Encrypt
#
# Security-first, idempotent where possible. Destructive ops clearly gated.

set -Eeuo pipefail

############################
# Versions / Paths
############################
GUAC_VER="1.6.0"
TOMCAT_VER="10.1.44"
MYSQLC_VER="8.4.0"
WORK="/tmp/guac-inst.$$"
BACKUP_DIR="/root/guac-backup-$(date +%F_%H%M%S)"
GUAC_HOME="/etc/guacamole"
TOMCAT_DIR="/opt/tomcat"
JAVA_HOME_DIR="/usr/lib/jvm/java-21-openjdk-amd64"  # OpenJDK 21 (Ubuntu 24.04)

# Defensive defaults to avoid "unbound variable" aborts
DOMAIN=""; ADMIN_EMAIL=""
Q14_XMS="512m"; Q14_XMX="1g"
Q19_ENFORCE_TOTP="N"; Q20_QC_DENY_PASS="Y"
Q16_EXTRA_ADMIN="N"; Q17_EXTRA_ADMIN_USER="admin"; Q18_EXTRA_ADMIN_PASS=""
Q18B_GUACD_BIND="127.0.0.1"
Q19B_HSTS="Y"

############################
# Helpers
############################
log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m  $*" >&2; }
die()  { err "$*"; exit 1; }
trap 'err "Failed at line $LINENO"; exit 1' ERR

require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

fix_tmp_perms() {
  # Fix earlier APT/tmp issues
  if [[ -d /tmp ]]; then
    chown root:root /tmp || true
    chmod 1777 /tmp || true
  fi
}

ask() {
  local prompt default varname
  prompt="$1"; default="${2:-}"; varname="$3"
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " REPLY
    REPLY="${REPLY:-$default}"
  else
    read -r -p "$prompt: " REPLY
  fi
  printf -v "$varname" "%s" "$REPLY"
}

ask_secret() {
  local prompt varname
  prompt="$1"; varname="$2"
  read -r -s -p "$prompt: " REPLY; echo
  printf -v "$varname" "%s" "$REPLY"
}

rand_hex() { tr -dc 'a-f0-9' </dev/urandom | head -c "${1:-32}"; }

must_install() {
  log "Installing packages: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

############################
# 1) Preflight Qs (20)
############################
preflight_questions() {
  echo "============================================================"
  echo "Pre-flight questions (20 total)"
  echo "============================================================"

  # 1
  ask "Q1) This will REMOVE old Guacamole/Tomcat/guacd and related dirs. Type YES to proceed" "" Q1_CONFIRM
  [[ "$Q1_CONFIRM" == "YES" ]] || die "Aborted by user."

  # 2
  echo "Q2) Deployment mode:"
  echo "    - Type 'direct' to expose Tomcat on :8080 (or your chosen port)"
  echo "    - Or 'nginx,<domain>,<email>' to install Nginx + Let's Encrypt (443)"
  ask "Your choice" "direct" Q2_MODE

  # 3
  ask "Q3) Tomcat HTTP port" "8080" Q3_PORT

  # 4
  ask "Q4) Web context path" "/guacamole" Q4_CTX
  Q4_CTX="${Q4_CTX#/}"; Q4_CTX="/$Q4_CTX"

  # 5/6/7
  ask "Q5) MariaDB database name" "guacamole_db" Q5_DB
  ask "Q6) MariaDB username" "guacamole_user" Q6_DBUSER
  ask_secret "Q7) MariaDB password (leave empty to auto-generate)" Q7_DBPASS
  [[ -n "$Q7_DBPASS" ]] || Q7_DBPASS="Guac$(rand_hex 12)"

  # 8/9
  ask "Q8) MariaDB root auth method [socket/password]" "socket" Q8_ROOTMODE
  if [[ "$Q8_ROOTMODE" == "password" ]]; then
    ask_secret "Enter MariaDB root password" Q8_ROOTPASS
  fi

  # 10
  ask "Q10) Enable TOTP 2FA? [Y/n]" "Y" Q9_TOTP

  # 11 (RDP now ENABLED since we install freerdp3-dev)
  ask "Q11) QuickConnect allowed protocols" "rdp,ssh,vnc" Q10_QCPROTO

  # 12
  ask "Q12) Session recording path" "/var/lib/guacamole/recordings" Q11_REC

  # 13
  local tz_default
  tz_default="$(cat /etc/timezone 2>/dev/null || echo "Africa/Cairo")"
  ask "Q13) Timezone" "$tz_default" Q13_TZ

  # 14
  ask "Q14) Tomcat heap (format: 'Xms Xmx')" "512m 1g" Q14_HEAP
  Q14_XMS="$(echo "$Q14_HEAP" | awk '{print $1}')"
  Q14_XMX="$(echo "$Q14_HEAP" | awk '{print $2}')"
  [[ -n "${Q14_XMS:-}" && -n "${Q14_XMX:-}" ]] || die "Invalid heap values."

  # 15
  ask "Q15) If DB exists, DROP and recreate? [y/N]" "N" Q15_DROP

  # 16/17/18: Optional extra admin (non-guacadmin)
  ask "Q16) Create an additional admin user now? [y/N]" "N" Q16_EXTRA_ADMIN
  if [[ "$Q16_EXTRA_ADMIN" =~ ^[yY]$ ]]; then
    ask "Q17) Extra admin username" "admin" Q17_EXTRA_ADMIN_USER
    ask_secret "Q18) Extra admin password (leave empty to auto-generate)" Q18_EXTRA_ADMIN_PASS
    [[ -n "$Q18_EXTRA_ADMIN_PASS" ]] || Q18_EXTRA_ADMIN_PASS="Adm$(rand_hex 12)"
  fi

  # 19: guacd bind
  ask "Q19) guacd bind address (127.0.0.1 for local only, 0.0.0.0 to expose)" "127.0.0.1" Q18B_GUACD_BIND

  # 20: quickconnect deny password param
  ask "Q20) QuickConnect: deny plaintext 'password' parameter? [Y/n]" "Y" Q20_QC_DENY_PASS

  # parse nginx params if selected
  if [[ "$Q2_MODE" == nginx,* ]]; then
    IFS=',' read -r MODE DOMAIN ADMIN_EMAIL <<<"$Q2_MODE"
    Q2_MODE="nginx"
    [[ -n "${DOMAIN:-}" && -n "${ADMIN_EMAIL:-}" ]] || die "nginx mode requires 'nginx,<domain>,<email>'."
    ask "Enable HSTS on Nginx? [Y/n]" "Y" Q19B_HSTS
  fi

  echo "============================================================"
  echo "Summary:"
  echo "  Mode          : $Q2_MODE ${DOMAIN:+($DOMAIN)}"
  echo "  Port/Path     : $Q3_PORT $Q4_CTX"
  echo "  DB            : $Q5_DB / $Q6_DBUSER"
  echo "  TOTP          : $Q9_TOTP"
  echo "  QuickConnect  : $Q10_QCPROTO (deny password: $Q20_QC_DENY_PASS)"
  echo "  Recording dir : $Q11_REC"
  echo "  Timezone      : $Q13_TZ"
  echo "  Heap          : -Xms${Q14_XMS} -Xmx${Q14_XMX}"
  echo "  RDP           : ENABLED (freerdp3-dev)"
  echo "  Drop DB       : $Q15_DROP"
  if [[ "$Q16_EXTRA_ADMIN" =~ ^[yY]$ ]]; then
    echo "  Extra admin   : $Q17_EXTRA_ADMIN_USER"
  fi
  echo "  guacd bind    : $Q18B_GUACD_BIND"
  echo "============================================================"
  read -r -p "Press ENTER to start, or Ctrl+C to abort..." _
}

############################
# 2) Cleanup / Backup
############################
cleanup_old() {
  log "Creating backup at $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  for p in "$GUAC_HOME" "$TOMCAT_DIR" /etc/systemd/system/{tomcat.service,guacd.service}; do
    [[ -e "$p" ]] && cp -a "$p" "$BACKUP_DIR/" || true
  done
  log "Stopping old services"
  systemctl stop tomcat 2>/dev/null || true
  systemctl stop guacd 2>/dev/null || true

  log "Removing old installation"
  rm -rf "$TOMCAT_DIR" "$GUAC_HOME" /usr/local/sbin/guacd /usr/local/lib/libguac* /usr/local/lib/guacamole /usr/local/include/guacamole || true
  rm -f /etc/systemd/system/{tomcat.service,guacd.service}
  systemctl daemon-reload || true
}

############################
# 3) Packages
############################
install_packages() {
  fix_tmp_perms
  log "apt update"
  apt-get update -y

  log "Installing base packages"
  must_install \
    curl wget ca-certificates gnupg lsb-release unzip tar rsync coreutils \
    openjdk-21-jre-headless tzdata \
    build-essential autoconf automake libtool pkg-config make gcc \
    libcairo2-dev libjpeg-turbo8-dev libpng-dev libwebp-dev \
    libossp-uuid-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    libpango1.0-dev libssh2-1-dev libtelnet-dev libvncserver-dev \
    libpulse-dev libssl-dev libvorbis-dev libwebsockets-dev \
    mariadb-server mariadb-client

  # RDP support with FreeRDP 3
  must_install freerdp3-dev freerdp3-x11 || warn "If guacd build fails, check FreeRDP 3 headers/runtime."

  if [[ "$Q2_MODE" == "nginx" ]]; then
    must_install nginx python3-certbot-nginx
  fi

  timedatectl set-timezone "$Q13_TZ" || true
}

############################
# 4) Build and install guacd (RDP enabled)
############################
install_guacd() {
  log "Building guacamole-server ${GUAC_VER} (with RDP via freerdp3)"
  mkdir -p "$WORK"; cd "$WORK"
  curl -fsSLO "https://archive.apache.org/dist/guacamole/${GUAC_VER}/source/guacamole-server-${GUAC_VER}.tar.gz"
  tar -xzf "guacamole-server-${GUAC_VER}.tar.gz"
  cd "guacamole-server-${GUAC_VER}"

  # Configure; FreeRDP 3 should be auto-detected via pkg-config
  ./configure \
    --with-init-dir=/etc/init.d \
    --disable-dependency-tracking

  make -j"$(nproc)"
  make install
  ldconfig

  log "Creating guacd systemd unit"
  tee /etc/systemd/system/guacd.service >/dev/null <<EOF
[Unit]
Description=Guacamole Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/guacd -f -l ${Q18B_GUACD_BIND} -p 4822
Restart=on-failure
User=root
Group=root
UMask=0027

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now guacd
  systemctl status --no-pager guacd || true
}

############################
# 5) Install Tomcat 10.1.44
############################
install_tomcat() {
  log "Installing Tomcat ${TOMCAT_VER}"
  mkdir -p "$TOMCAT_DIR"
  cd "$WORK"
  curl -fsSLO "https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz"
  tar -xzf "apache-tomcat-${TOMCAT_VER}.tar.gz"
  rsync -a "apache-tomcat-${TOMCAT_VER}/" "$TOMCAT_DIR/"
  id -u tomcat &>/dev/null || useradd -r -s /usr/sbin/nologin -d "$TOMCAT_DIR" tomcat
  chown -R tomcat:tomcat "$TOMCAT_DIR"

  # Adjust HTTP connector port (first occurrence)
  sed -i "0,/Connector port=\"8080\"/s//Connector port=\"${Q3_PORT}\"/" "$TOMCAT_DIR/conf/server.xml"

  log "Creating Tomcat systemd unit"
  tee /etc/systemd/system/tomcat.service >/dev/null <<EOF
[Unit]
Description=Apache Tomcat ${TOMCAT_VER}
After=network.target

[Service]
Type=simple
User=tomcat
Group=tomcat
Environment=JAVA_HOME=${JAVA_HOME_DIR}
Environment=CATALINA_BASE=${TOMCAT_DIR}
Environment=CATALINA_HOME=${TOMCAT_DIR}
Environment=GUACAMOLE_HOME=${GUAC_HOME}
Environment='JAVA_OPTS=-Xms${Q14_XMS} -Xmx${Q14_XMX} -Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager -Djava.util.logging.config.file=${TOMCAT_DIR}/conf/logging.properties --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.rmi/sun.rmi.transport=ALL-UNNAMED'
ExecStart=${TOMCAT_DIR}/bin/catalina.sh run
ExecStop=/bin/kill -15 \$MAINPID
SuccessExitStatus=143
Restart=on-failure
UMask=0027
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

############################
# 6) Deploy Guacamole client (Jakarta)
############################
deploy_guacamole_client() {
  log "Downloading Guacamole client WAR ${GUAC_VER}"
  cd "$WORK"
  curl -fsSLO "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war"

  log "Downloading Jakarta migration tool"
  # Primary coordinate per your fix, with fallback
  if ! curl -fsSLo jakartaee-migration.jar "https://repo1.maven.org/maven2/org/apache/tomcat/jakartaee-migration/1.0.9/jakartaee-migration-1.0.9-shaded.jar"; then
    curl -fsSLo jakartaee-migration.jar "https://repo1.maven.org/maven2/org/apache/tomcat/tomcat-jakartaee-migration/1.0.9/tomcat-jakartaee-migration-1.0.9-shaded.jar"
  fi

  log "Migrating WAR to Jakarta for Tomcat 10"
  java -jar jakartaee-migration.jar "guacamole-${GUAC_VER}.war" "guacamole-${GUAC_VER}-jakarta.war"

  # Honor custom context path by naming the war accordingly
  local WAR_BASENAME="${Q4_CTX#/}"  # strip leading slash
  install -o tomcat -g tomcat -m 0644 "guacamole-${GUAC_VER}-jakarta.war" "${TOMCAT_DIR}/webapps/${WAR_BASENAME}.war"
}

############################
# 7) Guacamole HOME + extensions (Jakarta)
############################
install_extensions_and_config() {
  log "Preparing $GUAC_HOME"
  install -d -m 0755 "$GUAC_HOME"/{extensions,lib}
  chown -R tomcat:tomcat "$GUAC_HOME"

  log "Downloading extensions (TOTP, QuickConnect, History Recording, JDBC MySQL)"
  cd "$WORK"
  curl -fsSLO "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-auth-totp-${GUAC_VER}.tar.gz"
  curl -fsSLO "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-auth-quickconnect-${GUAC_VER}.tar.gz"
  curl -fsSLO "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-history-recording-storage-${GUAC_VER}.tar.gz"
  curl -fsSLO "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz"

  tar -xzf "guacamole-auth-totp-${GUAC_VER}.tar.gz"
  tar -xzf "guacamole-auth-quickconnect-${GUAC_VER}.tar.gz"
  tar -xzf "guacamole-history-recording-storage-${GUAC_VER}.tar.gz"
  tar -xzf "guacamole-auth-jdbc-${GUAC_VER}.tar.gz"

  # Locate JARs (note: JDBC base jar is not shipped in 1.6.0; use mysql DB-specific jar)
  TOTP_JAR="$(find "guacamole-auth-totp-${GUAC_VER}" -maxdepth 1 -type f -name "*.jar" | head -n1 || true)"
  QC_JAR="$(find "guacamole-auth-quickconnect-${GUAC_VER}" -maxdepth 1 -type f -name "*.jar" | head -n1 || true)"
  REC_JAR="$(find "guacamole-history-recording-storage-${GUAC_VER}" -maxdepth 1 -type f -name "*.jar" | head -n1 || true)"
  JDBC_MYSQL_JAR="$(find "guacamole-auth-jdbc-${GUAC_VER}/mysql" -maxdepth 1 -type f -name "*.jar" | head -n1 || true)"
  [[ -n "$JDBC_MYSQL_JAR" ]] || die "Could not find JDBC MySQL extension jar."

  # Migrate all extensions to Jakarta
  for J in "$TOTP_JAR" "$QC_JAR" "$REC_JAR" "$JDBC_MYSQL_JAR"; do
    [[ -f "$J" ]] || continue
    OUT="${WORK}/$(basename "${J%.jar}").jakarta.jar"
    java -jar jakartaee-migration.jar "$J" "$OUT"
    unzip -tq "$OUT" >/dev/null 2>&1 || die "Invalid migrated jar: $OUT"
    install -o tomcat -g tomcat -m 0644 "$OUT" "${GUAC_HOME}/extensions/"
  done

  log "Installing JDBC driver (MySQL Connector/J ${MYSQLC_VER})"
  curl -fsSLo "${GUAC_HOME}/lib/mysql-connector-j-${MYSQLC_VER}.jar" \
    "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQLC_VER}/mysql-connector-j-${MYSQLC_VER}.jar"
  chown tomcat:tomcat "${GUAC_HOME}/lib/mysql-connector-j-${MYSQLC_VER}.jar"

  local QC_DENY_LINE=""
  if [[ "$Q20_QC_DENY_PASS" =~ ^[Yy]$ ]]; then
    QC_DENY_LINE=$'\nquickconnect-denied-parameters: password'
  fi

  log "Writing guacamole.properties"
  tee "${GUAC_HOME}/guacamole.properties" >/dev/null <<EOF
# guacd
guacd-hostname: ${Q18B_GUACD_BIND}
guacd-port: 4822

# MariaDB JDBC
mysql-hostname: 127.0.0.1
mysql-port: 3306
mysql-database: ${Q5_DB}
mysql-username: ${Q6_DBUSER}
mysql-password: ${Q7_DBPASS}

# Features
recording-search-path: ${Q11_REC}
quickconnect-allowed-protocols: ${Q10_QCPROTO}
use-remote-address: false${QC_DENY_LINE}
EOF

  chown tomcat:tomcat "${GUAC_HOME}/guacamole.properties"
  install -d -m 0755 "${Q11_REC}"
  chown -R tomcat:tomcat "${Q11_REC}"
}

############################
# 8) MariaDB setup
############################
setup_mariadb() {
  log "Configuring MariaDB (DB: ${Q5_DB}, User: ${Q6_DBUSER})"
  systemctl enable --now mariadb

  local mysql_cmd="mariadb"
  if [[ "${Q8_ROOTMODE}" == "password" ]]; then
    mysql_cmd="mariadb -u root -p${Q8_ROOTPASS}"
  fi

  if [[ "$Q15_DROP" =~ ^[yY]$ ]]; then
    eval "$mysql_cmd" <<SQL
DROP DATABASE IF EXISTS \`${Q5_DB}\`;
SQL
  fi

  eval "$mysql_cmd" <<SQL
CREATE DATABASE IF NOT EXISTS \`${Q5_DB}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${Q6_DBUSER}'@'localhost' IDENTIFIED BY '${Q7_DBPASS}';
GRANT ALL ON \`${Q5_DB}\`.* TO '${Q6_DBUSER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  # Load schema + default admin
  local SCHEMA_DIR
  SCHEMA_DIR="$(find "$WORK/guacamole-auth-jdbc-${GUAC_VER}/mysql/schema" -maxdepth 0 -type d)"
  [[ -d "$SCHEMA_DIR" ]] || die "Schema dir not found"
  mariadb "${Q5_DB}" < "${SCHEMA_DIR}/001-create-schema.sql"
  mariadb "${Q5_DB}" < "${SCHEMA_DIR}/002-create-admin-user.sql"
  mariadb "${Q5_DB}" < "${SCHEMA_DIR}/003-create-preferences.sql"

  # Optional: create extra admin (correct hashing like 002 script)
  if [[ "$Q16_EXTRA_ADMIN" =~ ^[yY]$ ]]; then
    local SALT HASH USER PASS
    USER="${Q17_EXTRA_ADMIN_USER}"
    PASS="${Q18_EXTRA_ADMIN_PASS}"
    SALT="$(rand_hex 64)"  # 32 bytes hex
    HASH="$(printf "%s" "${PASS}" | iconv -t UTF-8 | xxd -p -c9999 | tr -d '\n' | awk '{print tolower($0)}')"
    # Compute SHA256(CONCAT(password, salt)) in SQL to avoid locale issues
    mariadb "${Q5_DB}" <<EOSQL
SET @now = NOW();
SET @salt = UNHEX('${SALT}');
SET @hash = UNHEX(SHA2(CONCAT('${PASS}', HEX(@salt)), 256));
INSERT INTO guacamole_entity (name, type) VALUES ('${USER}', 'USER');
SET @eid = LAST_INSERT_ID();
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date, disabled, expired)
VALUES (@eid, @hash, @salt, @now, 0, 0);
-- Admin system permissions (mirror of 002 script)
INSERT INTO guacamole_system_permission (entity_id, permission) VALUES
  (@eid, 'ADMINISTER'), (@eid, 'CREATE_CONNECTION'), (@eid, 'CREATE_CONNECTION_GROUP'),
  (@eid, 'CREATE_SHARING_PROFILE'), (@eid, 'CREATE_USER');
EOSQL
  fi

  # Verify default admin via proper join
  mariadb -N -e "
SELECT e.name AS username, u.disabled
FROM guacamole_entity e JOIN guacamole_user u ON u.entity_id=e.entity_id
WHERE e.type='USER' AND e.name='guacadmin';" "${Q5_DB}" || true
}

############################
# 9) Nginx (optional)
############################
configure_nginx() {
  [[ "$Q2_MODE" == "nginx" ]] || return 0

  log "Configuring Nginx reverse proxy for ${DOMAIN}"
  local HSTS=""
  [[ "$Q19B_HSTS" =~ ^[Yy]$ ]] && HSTS=$'add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;'

  tee /etc/nginx/sites-available/guacamole.conf >/dev/null <<EOF
server {
  listen 80;
  server_name ${DOMAIN};
  location /.well-known/acme-challenge/ { root /var/www/html; }
  location = / { return 301 ${Q4_CTX}/; }
}
EOF

  ln -sf /etc/nginx/sites-available/guacamole.conf /etc/nginx/sites-enabled/guacamole.conf
  nginx -t
  systemctl restart nginx

  log "Requesting Let's Encrypt certificate"
  certbot --nginx -d "${DOMAIN}" --email "${ADMIN_EMAIL}" --agree-tos --non-interactive || warn "Certbot failed – continuing in HTTP"
  # Final HTTPS vhost
  tee /etc/nginx/sites-available/guacamole.conf >/dev/null <<EOF
server {
  listen 80;
  server_name ${DOMAIN};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name ${DOMAIN};
  ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
  ${HSTS}

  location = / { return 301 ${Q4_CTX}/; }

  location ${Q4_CTX}/ {
    proxy_pass http://127.0.0.1:${Q3_PORT}${Q4_CTX}/;
    proxy_buffering off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-Server \$host;
    proxy_read_timeout 900;
  }
}
EOF

  nginx -t
  systemctl reload nginx
}

############################
# 10) Start services
############################
start_services() {
  log "Starting Tomcat"
  systemctl enable --now tomcat
  sleep 6
  journalctl -u tomcat -n 80 --no-pager | egrep -i "Loaded extension|mysql|jdbc|ERROR|SEVERE" || true
}

############################
# Main
############################
main() {
  require_root
  mkdir -p "$WORK"
  preflight_questions
  cleanup_old
  install_packages
  install_guacd
  install_tomcat
  deploy_guacamole_client
  install_extensions_and_config
  setup_mariadb
  configure_nginx
  start_services

  echo
  log "Done."
  echo "----------------------------------------------------------------"
  if [[ "$Q2_MODE" == "nginx" ]]; then
    echo "Open: https://${DOMAIN}${Q4_CTX}/"
  else
    echo "Open: http://<server-ip>:${Q3_PORT}${Q4_CTX}/"
  fi
  echo
  echo "Login with: guacadmin / guacadmin  (change immediately, then disable)"
  if [[ "$Q16_EXTRA_ADMIN" =~ ^[yY]$ ]]; then
    echo "Extra admin created: ${Q17_EXTRA_ADMIN_USER}"
  fi
  echo "RDP: ENABLED (freerdp3-dev)"
  echo "Recording dir: ${Q11_REC}"
  echo "QuickConnect protocols: ${Q10_QCPROTO} (deny password: ${Q20_QC_DENY_PASS})"
  echo "Config: ${GUAC_HOME}/guacamole.properties"
  echo "Extensions: ${GUAC_HOME}/extensions"
  echo "JDBC driver: ${GUAC_HOME}/lib/mysql-connector-j-${MYSQLC_VER}.jar"
  echo "Services: systemctl status guacd, tomcat"
  echo "Backups at: ${BACKUP_DIR}"
  echo "----------------------------------------------------------------"
}
main
