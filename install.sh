#!/usr/bin/env bash
# =====================================================================
# Apache Guacamole 1.6.0 on Ubuntu 24.04 (JAKARTA / Tomcat 10.1.44)
# Fresh, destructive reinstall with backups:
# - guacd 1.6.0 from source
# - Tomcat 10.1.44 (manual)
# - MariaDB JDBC auth (DB: guacamole_db / User: guacamole_user / Pass: 123Beta)
# - Extensions: JDBC, TOTP, QuickConnect, Encrypted JSON, History Player
# - Jakarta migration applied to WAR + extension JARs
# - Idempotent: backs up & DROPS any existing Guacamole DB for a truly fresh install
# =====================================================================
set -euo pipefail
IFS=$'\n\t'
umask 022

# ---------------------------- Versions ----------------------------
GUAC_VER="1.6.0"
TOMCAT_VER="10.1.44"
MARIADB_JDBC_VER="3.5.5"
MIGR_VER="1.0.9"  # tomcat-jakartaee-migration shaded jar

# ---------------------------- Constants ---------------------------
DB_NAME="guacamole_db"
DB_USER="guacamole_user"
DB_PASS="123Beta"

TOMCAT_BASE="/opt/tomcat"
GUAC_HOME="/etc/guacamole"
EXT_DIR="${GUAC_HOME}/extensions"
LIB_DIR="${GUAC_HOME}/lib"
REC_DIR_DEFAULT="/var/lib/guacamole/recordings"

GUAC_BASE_BIN="https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary"
GUAC_BASE_SRC="https://archive.apache.org/dist/guacamole/${GUAC_VER}/source"
MARIADB_JDBC_URL="https://repo1.maven.org/maven2/org/mariadb/jdbc/mariadb-java-client/${MARIADB_JDBC_VER}/mariadb-java-client-${MARIADB_JDBC_VER}.jar"

TOMCAT_URL_PRIMARY="https://dlcdn.apache.org/tomcat/tomcat-10/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz"
TOMCAT_URL_FALLBACK="https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz"

MIGR_JAR_URL="https://repo1.maven.org/maven2/org/apache/tomcat/tomcat-jakartaee-migration/${MIGR_VER}/tomcat-jakartaee-migration-${MIGR_VER}-shaded.jar"

DISABLED_SOURCES_DIR="/etc/apt/disabled-$(date +%F_%H%M%S)"

# ------------------------- Root & /tmp sanity -----------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0"
  exit 1
fi

export TMPDIR=/tmp
mkdir -p /tmp
chown root:root /tmp
chmod 1777 /tmp
mountpoint -q /tmp && mount -o remount,rw /tmp || true

# --------------------------- Logging --------------------------------
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
green()  { printf "\033[1;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
red()    { printf "\033[1;31m%s\033[0m\n" "$*"; }
log()    { echo; green "==> $*"; echo; }

trap 'red "ERROR: Script aborted."; systemctl --no-pager status guacd tomcat || true; journalctl -u tomcat -n 80 --no-pager || true' ERR

# ------------------------ Helper functions --------------------------
download() {
  local url="$1" out="$2"
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 1 -o "${out}" "${url}"
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing required command: $1"; exit 1; }
}

apt_update_retry() {
  export DEBIAN_FRONTEND=noninteractive
  local tries=0 max=3
  until apt-get update; do
    tries=$((tries+1))
    if (( tries >= max )); then
      yellow "APT update failed $tries times. Temporarily disabling common third-party sources & ESM, then retrying..."
      mkdir -p "$DISABLED_SOURCES_DIR"
      find /etc/apt/sources.list.d -maxdepth 1 -type f \( \
        -iname "*ondrej*.list" -o -iname "*mongodb*.list" -o -iname "*mariadb*.list" -o -iname "*maxscale*.list" \
      \) -exec mv -v {} "$DISABLED_SOURCES_DIR"/ \; || true
      sed -i.bak -E 's/^(deb .*esm\.ubuntu\.com.*)$/# \1/g' /etc/apt/sources.list || true
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      apt-get update
      break
    fi
    sleep 1
  done
}

install_pkgs() {
  apt-get install -y -o Dpkg::Use-Pty=0 "$@"
}

migrate_artifact() {
  local SRC="$1" DEST="$2"
  if command -v javax2jakarta >/dev/null 2>&1; then
    javax2jakarta "${SRC}" "${DEST}"
  else
    [[ -f /tmp/tomcat-jakartaee-migration.jar ]] || download "${MIGR_JAR_URL}" /tmp/tomcat-jakartaee-migration.jar
    java -jar /tmp/tomcat-jakartaee-migration.jar "${SRC}" "${DEST}"
  fi
}

# --------------------- 5 QUESTIONS (pre-flight) ---------------------
bold "============================================================"
bold "Pre-flight questions (5 total)"
bold "============================================================"

read -r -p "Q1) This will REMOVE old Guacamole/Tomcat and DROP any existing Guacamole DB. Type YES to proceed: " Q_CONFIRM
[[ "${Q_CONFIRM}" == "YES" ]] || { red "Aborted."; exit 1; }

echo "Q2) Deployment mode:
    - Type 'direct' to expose Tomcat on :8080
    - Or 'nginx,<domain>,<email>' to install Nginx reverse proxy and attempt Let's Encrypt"
read -r -p "    Your choice [direct OR nginx,example.com,admin@example.com]: " Q_MODE

DEPLOY_MODE="direct"
NGINX_DOMAIN=""
NGINX_EMAIL=""
if [[ "${Q_MODE}" == "direct" ]]; then
  DEPLOY_MODE="direct"
elif [[ "${Q_MODE}" == nginx,* ]]; then
  DEPLOY_MODE="nginx"
  IFS=',' read -r _ NGINX_DOMAIN NGINX_EMAIL <<< "${Q_MODE}"
  [[ -n "${NGINX_DOMAIN}" && -n "${NGINX_EMAIL}" ]] || { red "Invalid nginx input. Use: nginx,domain,email"; exit 1; }
else
  red "Invalid choice."; exit 1
fi

read -r -p "Q3) Encrypted JSON 'json-secret-key' (32 hex chars) or 'auto' to generate: " Q_JSON
if [[ -z "${Q_JSON}" || "${Q_JSON}" == "auto" ]]; then
  JSON_SECRET="$(openssl rand -hex 16)"
else
  JSON_SECRET="${Q_JSON}"
fi
[[ "${JSON_SECRET}" =~ ^[0-9a-fA-F]{32}$ ]] || { red "json-secret-key must be exactly 32 hex chars."; exit 1; }

read -r -p "Q4) QuickConnect allowed protocols [default: rdp,ssh,vnc]: " Q_QC
QC_ALLOWED="${Q_QC:-rdp,ssh,vnc}"

read -r -p "Q5) Session recording path [default: ${REC_DIR_DEFAULT}]: " Q_REC
REC_DIR="${Q_REC:-$REC_DIR_DEFAULT}"

bold "============================================================"
echo "Summary:"
echo "  Mode          : ${DEPLOY_MODE}"
[[ "${DEPLOY_MODE}" == "nginx" ]] && echo "  Nginx domain  : ${NGINX_DOMAIN} (email: ${NGINX_EMAIL})"
echo "  JSON secret   : ${JSON_SECRET}"
echo "  QuickConnect  : ${QC_ALLOWED}"
echo "  Recording dir : ${REC_DIR}"
bold "============================================================"
read -r -p "Press ENTER to start, or Ctrl+C to abort..." _

# ----------------------- Backups & cleanup --------------------------
log "Backing up any existing Guacamole/Tomcat/guacd directories"
BK="/root/guac-backup-$(date +%F_%H%M%S)"
mkdir -p "${BK}"
for p in /etc/guacamole /opt/tomcat /var/lib/tomcat* /usr/local/sbin/guacd /usr/local/lib/guacamole; do
  [[ -e "$p" ]] && tar -C / -czf "${BK}$(echo $p | tr / _).tgz" "${p#/}" || true
done
echo "Backups in ${BK}"

log "Removing previous installations (destructive)"
systemctl stop tomcat* guacd 2>/dev/null || true
apt_update_retry
apt-get purge -y -o Dpkg::Use-Pty=0 'tomcat*' 'guacamole*' 'libguac*' || true
apt-get autoremove -y -o Dpkg::Use-Pty=0
rm -rf /opt/tomcat /var/lib/tomcat* /etc/tomcat* /etc/guacamole \
       /usr/local/sbin/guacd /usr/local/lib/guacamole /usr/local/share/guacamole
rm -f /etc/systemd/system/{guacd,tomcat}.service
systemctl daemon-reload

# ----------------------- Base packages ------------------------------
log "Installing base packages & build deps"
apt_update_retry
install_pkgs build-essential pkg-config \
  libcairo2-dev libpng-dev libjpeg-turbo8-dev libtool-bin uuid-dev \
  libssh2-1-dev libtelnet-dev libvncserver-dev \
  libpulse-dev libvorbis-dev libwebp-dev libavcodec-dev libavformat-dev libavutil-dev \
  libssl-dev libpango1.0-dev libwebsockets-dev \
  fonts-dejavu-core ca-certificates wget curl unzip gnupg openssl \
  openjdk-21-jdk mariadb-server mariadb-client

ensure_cmd java
ensure_cmd openssl
ensure_cmd curl
ensure_cmd mariadb
ensure_cmd mariadb-dump

# ----------------------- Build guacd -------------------------------
log "Building guacd ${GUAC_VER} from source"
cd /tmp
download "${GUAC_BASE_SRC}/guacamole-server-${GUAC_VER}.tar.gz" "/tmp/guacamole-server-${GUAC_VER}.tar.gz"
tar -xzf "guacamole-server-${GUAC_VER}.tar.gz"
cd "guacamole-server-${GUAC_VER}"
./configure --with-systemd-dir=/etc/systemd/system
make -j"$(nproc)"
make install
ldconfig

id guacd >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin guacd

cat >/etc/systemd/system/guacd.service <<'UNIT'
[Unit]
Description=Guacamole Server
After=network.target
[Service]
Type=simple
User=guacd
Group=guacd
ExecStart=/usr/local/sbin/guacd -f
Restart=always
RestartSec=2
# Hardening
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now guacd

# ----------------------- Install Tomcat 10 --------------------------
log "Installing Tomcat ${TOMCAT_VER}"
groupadd --system tomcat 2>/dev/null || true
id tomcat >/dev/null 2>&1 || useradd --system -g tomcat -d "${TOMCAT_BASE}" -s /usr/sbin/nologin tomcat

cd /tmp
if ! download "${TOMCAT_URL_PRIMARY}" "/tmp/apache-tomcat-${TOMCAT_VER}.tar.gz"; then
  download "${TOMCAT_URL_FALLBACK}" "/tmp/apache-tomcat-${TOMCAT_VER}.tar.gz"
fi
mkdir -p "${TOMCAT_BASE}"
tar -xzf "/tmp/apache-tomcat-${TOMCAT_VER}.tar.gz" -C "${TOMCAT_BASE}" --strip-components=1
chown -R tomcat:tomcat "${TOMCAT_BASE}"

mkdir -p "${GUAC_HOME}/"{extensions,lib}
cat >"${TOMCAT_BASE}/bin/setenv.sh" <<'EOF'
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export GUACAMOLE_HOME=/etc/guacamole
# export CATALINA_OPTS="-Xms512m -Xmx1024m -XX:+UseG1GC"
EOF
chown tomcat:tomcat "${TOMCAT_BASE}/bin/setenv.sh"
chmod +x "${TOMCAT_BASE}/bin/setenv.sh"

cat >/etc/systemd/system/tomcat.service <<'UNIT'
[Unit]
Description=Apache Tomcat 10
After=network.target
[Service]
User=tomcat
Group=tomcat
Environment="JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64"
Environment="CATALINA_BASE=/opt/tomcat"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="GUACAMOLE_HOME=/etc/guacamole"
ExecStart=/opt/tomcat/bin/catalina.sh run
ExecStop=/opt/tomcat/bin/catalina.sh stop
SuccessExitStatus=143
Restart=always
# Hardening
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now tomcat

# ------------------- Download WAR + Extensions ----------------------
log "Downloading Guacamole ${GUAC_VER} WAR and extensions"
cd /tmp
download "${GUAC_BASE_BIN}/guacamole-${GUAC_VER}.war" "/tmp/guacamole-${GUAC_VER}.war"

for f in \
  guacamole-auth-jdbc-${GUAC_VER}.tar.gz \
  guacamole-auth-totp-${GUAC_VER}.tar.gz \
  guacamole-auth-quickconnect-${GUAC_VER}.tar.gz \
  guacamole-auth-json-${GUAC_VER}.tar.gz \
  guacamole-history-recording-storage-${GUAC_VER}.tar.gz
do
  download "${GUAC_BASE_BIN}/${f}" "/tmp/${f}"
  tar -xzf "/tmp/${f}" -C /tmp
done

# -------------------- Jakarta migration (WAR/JARs) ------------------
log "Applying Jakarta migration to WAR + extensions"
if ! command -v javax2jakarta >/dev/null 2>&1; then
  apt_update_retry
  install_pkgs tomcat-jakartaee-migration || true
fi

mkdir -p /tmp/guac-jakarta /tmp/ext-src /tmp/ext-jakarta

# Collect extension jars into /tmp/ext-src
find /tmp -maxdepth 2 -type f -name "*.jar" -path "*guacamole-auth-*/*" -exec cp -v {} /tmp/ext-src/ \; || true

# Migrate WAR
migrate_artifact "/tmp/guacamole-${GUAC_VER}.war" "/tmp/guac-jakarta/guacamole-${GUAC_VER}.war"

# Sanity: migrated WAR should be ~7–8 MB
WAR_SIZE=$(stat -c%s "/tmp/guac-jakarta/guacamole-${GUAC_VER}.war")
if (( WAR_SIZE < 5000000 )); then
  red "Migrated WAR is too small (${WAR_SIZE} bytes). Migration failed. Aborting."
  exit 1
fi

# Migrate each extension JAR
shopt -s nullglob
for J in /tmp/ext-src/*.jar; do
  BN="$(basename "$J")"
  migrate_artifact "$J" "/tmp/ext-jakarta/${BN}"
done
shopt -u nullglob

# ------------------ Deploy migrated artifacts -----------------------
log "Deploying migrated WAR and extensions"
cp "/tmp/guac-jakarta/guacamole-${GUAC_VER}.war" "${TOMCAT_BASE}/webapps/guacamole.war"
chown tomcat:tomcat "${TOMCAT_BASE}/webapps/guacamole.war"

EXT_COUNT=$(ls -1 /tmp/ext-jakarta/*.jar 2>/dev/null | wc -l || true)
if (( EXT_COUNT == 0 )); then
  yellow "No extension jars were found after migration; check earlier steps."
else
  cp -v /tmp/ext-jakarta/*.jar "${EXT_DIR}/" || true
fi

# JDBC driver
download "${MARIADB_JDBC_URL}" "/tmp/mariadb-java-client.jar"
mv /tmp/mariadb-java-client.jar "${LIB_DIR}/"
chown -R tomcat:tomcat "${GUAC_HOME}"

# -------------------- MariaDB: DB fresh init ------------------------
log "Configuring MariaDB (DROP/CREATE ${DB_NAME}, user ${DB_USER})"
systemctl enable --now mariadb

# BACKUP if DB exists
if mariadb -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}'" | grep -q "${DB_NAME}"; then
  yellow "Existing database '${DB_NAME}' detected. Backing it up, then dropping for a FRESH install."
  BKSQL="${BK}/db_${DB_NAME}_$(date +%F_%H%M%S).sql.gz"
  mariadb-dump "${DB_NAME}" | gzip -9 > "${BKSQL}" || true
  echo "Backup saved: ${BKSQL}"
  mariadb -e "DROP DATABASE \`${DB_NAME}\`;"
fi

# Fresh DB/user
mariadb -e "CREATE DATABASE \`${DB_NAME}\` /*\!40100 DEFAULT CHARACTER SET utf8 */;"
mariadb -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "GRANT SELECT,INSERT,UPDATE,DELETE ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

SCHEMA_DIR="/tmp/guacamole-auth-jdbc-${GUAC_VER}/mysql/schema"
if [[ -d "${SCHEMA_DIR}" ]]; then
  cat ${SCHEMA_DIR}/*.sql | mariadb "${DB_NAME}"
else
  red "JDBC schema not found at ${SCHEMA_DIR}"; exit 1
fi

# ---------------- Recording path & permissions ----------------------
log "Preparing session recording directory: ${REC_DIR}"
mkdir -p "${REC_DIR}"
chown -R guacd:tomcat "${REC_DIR}"
chmod -R 2750 "${REC_DIR}"

# ------------------- guacamole.properties ---------------------------
log "Writing ${GUAC_HOME}/guacamole.properties"
USE_REMOTE_ADDRESS="false"
[[ "${DEPLOY_MODE}" == "nginx" ]] && USE_REMOTE_ADDRESS="true"

cat >"${GUAC_HOME}/guacamole.properties" <<PROP
# ---- guacd ----
guacd-hostname: 127.0.0.1
guacd-port: 4822

# ---- JDBC (MariaDB/MySQL) ----
mysql-hostname: 127.0.0.1
mysql-port: 3306
mysql-database: ${DB_NAME}
mysql-username: ${DB_USER}
mysql-password: ${DB_PASS}

# ---- TOTP (MFA) ----
# totp-issuer: Beta Digital Technology

# ---- Recording Player ----
recording-search-path: ${REC_DIR}

# ---- QuickConnect (ad-hoc) ----
quickconnect-allowed-protocols: ${QC_ALLOWED}
# quickconnect-denied-parameters: password

# ---- Encrypted JSON auth ----
json-secret-key: ${JSON_SECRET}

# ---- Honor client IP from reverse proxy ----
use-remote-address: ${USE_REMOTE_ADDRESS}
PROP

chown -R tomcat:tomcat "${GUAC_HOME}"

# ------------------ Optional Nginx reverse proxy --------------------
if [[ "${DEPLOY_MODE}" == "nginx" ]]; then
  log "Installing Nginx reverse proxy"
  apt_update_retry
  install_pkgs nginx certbot python3-certbot-nginx

  cat >/etc/nginx/sites-available/guacamole.conf <<NGX
server {
    listen 80;
    server_name ${NGINX_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:8080/guacamole/;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGX
  ln -sf /etc/nginx/sites-available/guacamole.conf /etc/nginx/sites-enabled/guacamole.conf
  nginx -t && systemctl restart nginx

  yellow "Attempting Let's Encrypt certificate via certbot (domain must resolve here; port 80 open)."
  if ! certbot --nginx -d "${NGINX_DOMAIN}" --non-interactive --agree-tos -m "${NGINX_EMAIL}"; then
    yellow "Certbot failed; you can re-run: certbot --nginx -d ${NGINX_DOMAIN} -m ${NGINX_EMAIL} --agree-tos"
  fi
fi

# --------------------- Restart & health checks ----------------------
log "Restarting Tomcat to load Guacamole"
systemctl restart tomcat

# Wait for app to deploy and respond
log "HTTP health check for Guacamole"
for i in {1..20}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/guacamole/ || true)
  if [[ "$code" =~ ^(200|302|401)$ ]]; then
    echo "Healthy (HTTP ${code})"
    break
  fi
  sleep 1
  [[ $i -eq 20 ]] && yellow "Guacamole not responding yet (last code ${code}). Check logs."
done

# Ports & services
systemctl --no-pager status guacd tomcat || true
ss -lntp | grep -E ':4822|:8080' || true

# --------------------------- Summary --------------------------------
bold "============================================================"
bold "Guacamole deployment complete (Jakarta path)"
if [[ "${DEPLOY_MODE}" == "nginx" ]]; then
  echo "URL:  http${USE_REMOTE_ADDRESS:+s}://${NGINX_DOMAIN}/"
else
  echo "URL:  http://<server-ip>:8080/guacamole/"
fi
echo
echo "Login (created by JDBC schema) → change immediately:"
echo "  Username: guacadmin"
echo "  Password: guacadmin"
echo
echo "DB: ${DB_NAME} | User: ${DB_USER} | Pass: ${DB_PASS}   (rotate in production)"
echo "JSON secret key (in guacamole.properties): ${JSON_SECRET}"
echo "Recording directory: ${REC_DIR}"
echo "QuickConnect allowed protocols: ${QC_ALLOWED}"
if [[ -d "$DISABLED_SOURCES_DIR" ]]; then
  yellow "NOTE: Some APT sources were temporarily disabled: $DISABLED_SOURCES_DIR"
  yellow "      Review/restore as needed after install."
fi
bold "============================================================"
