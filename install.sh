#!/usr/bin/env bash
set -Eeuo pipefail
REPO=""; BRANCH="main"; PORT="80"; DOMAIN="_"; SOURCE=""
while (($#)); do case "$1" in
 --repo) REPO="${2:?--repo requires URL}"; shift 2;; --branch) BRANCH="${2:?}"; shift 2;;
 --port) PORT="${2:?}"; shift 2;; --domain) DOMAIN="${2:?}"; shift 2;;
 -h|--help) echo "Usage: sudo bash install.sh [--repo https://github.com/OWNER/REPO.git] [--branch main] [--port 80] [--domain example.com]"; exit 0;;
 *) echo "Unknown option: $1" >&2; exit 2;; esac; done
[[ $EUID -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
[[ $PORT =~ ^[0-9]+$ ]] && ((PORT>0 && PORT<65536)) || { echo 'Invalid --port (1..65535)' >&2; exit 2; }
if [[ -n "$REPO" ]]; then
 command -v git >/dev/null || { apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y git; }
 TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
 git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMP/repo"
 SOURCE="$TMP/repo"
else
 SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
[[ -f "$SOURCE/requirements.txt" && -f "$SOURCE/app/main.py" ]] || { echo 'Source is not a work-hours-rubika project.' >&2; exit 1; }
APP=/opt/work-hours-rubika; STATE=/var/lib/work-hours-rubika; ENVFILE=/etc/work-hours-rubika.env
if [[ -e "$APP" && ! -f "$APP/.work-hours-rubika-install" ]]; then echo "Refusing to overwrite unrelated $APP (missing marker). Back it up/move it manually." >&2; exit 1; fi
if [[ -e "$APP" && ! -d "$APP" ]]; then echo "Install path is not a directory: $APP" >&2; exit 1; fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip git nginx curl ca-certificates rsync
getent group workhours >/dev/null || groupadd --system workhours
id -u workhours >/dev/null 2>&1 || useradd --system --gid workhours --home-dir "$STATE" --no-create-home --shell /usr/sbin/nologin workhours
install -d -o root -g workhours -m 0750 "$APP"
install -d -o workhours -g workhours -m 0750 "$STATE" "$STATE/files" "$STATE/backups"
# Stage a clean source tree before replacing tracked code; never copy repo runtime/secrets.
STAGE="$(mktemp -d /opt/.work-hours-stage.XXXXXX)"; trap '[[ -z "${TMP:-}" ]] || rm -rf "$TMP"; [[ -z "${STAGE:-}" ]] || rm -rf "$STAGE"' EXIT
rsync -a --delete --exclude=.git --exclude=data --exclude=.env --exclude=.venv --exclude=venv --exclude=__pycache__ --exclude=.pytest_cache "$SOURCE/" "$STAGE/"
if [[ -f "$ENVFILE" ]]; then chmod 600 "$ENVFILE"; chown root:workhours "$ENVFILE"; else
 ADMIN="admin"; PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"; KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
 printf '%s=%s\n' FIRST_ADMIN_USERNAME "$ADMIN" FIRST_ADMIN_PASSWORD "$PASS" SECRET_KEY "$KEY" WORKHOURS_DATA_DIR "$STATE" WORKHOURS_DB_PATH "$STATE/app.db" > "$ENVFILE"
 chown root:workhours "$ENVFILE"; chmod 600 "$ENVFILE"
 echo 'Initial administrator credentials (shown only at first install; save now):'; echo "Username: $ADMIN"; echo "Password: $PASS"
fi
# Require admin configuration when no account exists; do not print previously existing credentials.
if [[ ! -f "$STATE/app.db" ]]; then
 set -a; source "$ENVFILE"; set +a
 [[ -n "${FIRST_ADMIN_USERNAME:-}" && ${#FIRST_ADMIN_PASSWORD} -ge 12 && ${#SECRET_KEY} -ge 32 ]] || { echo 'Invalid initial admin / SECRET_KEY in env file.' >&2; exit 1; }
fi
rsync -a --delete "$STAGE/" "$APP/"
touch "$APP/.work-hours-rubika-install"; chown -R root:workhours "$APP"; find "$APP" -type d -exec chmod 0750 {} +; find "$APP" -type f -exec chmod 0640 {} +; chmod 0750 "$APP/install.sh"
python3 -m venv "$APP/.venv"
"$APP/.venv/bin/pip" install --upgrade pip
"$APP/.venv/bin/pip" install -r "$APP/requirements.txt"
cat >/etc/systemd/system/work-hours-rubika.service <<EOF
[Unit]
Description=Work Hours Rubika web application
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=workhours
Group=workhours
WorkingDirectory=$APP
EnvironmentFile=$ENVFILE
Environment=WORKHOURS_DATA_DIR=$STATE
Environment=WORKHOURS_DB_PATH=$STATE/app.db
RuntimeDirectory=work-hours-rubika
RuntimeDirectoryMode=0750
UMask=0027
ExecStart=$APP/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 1
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$STATE /run/work-hours-rubika
[Install]
WantedBy=multi-user.target
EOF
# Add one owned nginx server file; retain unrelated sites and refuse an exact-name collision.
NG=/etc/nginx/sites-available/work-hours-rubika
if [[ -e "$NG" && ! -f /etc/nginx/sites-enabled/work-hours-rubika ]]; then echo "Refusing to overwrite existing nginx config $NG; inspect/move it manually." >&2; exit 1; fi
if [[ -e /etc/nginx/sites-enabled/work-hours-rubika ]]; then
 echo 'Existing work-hours-rubika nginx site will be updated; unrelated sites are untouched.'
fi
if grep -RqsE "listen[[:space:]]+([^;]*:)?${PORT}([[:space:];]|$)" /etc/nginx/sites-enabled --exclude=work-hours-rubika 2>/dev/null; then
 echo "Port $PORT appears in another enabled nginx site. Choose another --port or resolve conflict; no config removed." >&2; exit 1
fi
cat >"$NG" <<EOF
server {
    listen $PORT;
    server_name $DOMAIN;
    client_max_body_size 25m;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sfn "$NG" /etc/nginx/sites-enabled/work-hours-rubika
nginx -t
systemctl daemon-reload
systemctl enable --now work-hours-rubika
systemctl restart work-hours-rubika
systemctl reload nginx
OK=0
for _ in $(seq 1 40); do if curl -fsS http://127.0.0.1:8000/login >/dev/null; then OK=1; break; fi; sleep 1; done
[[ $OK -eq 1 ]] || { echo 'Service did not pass HTTP /login health check. Check: journalctl -u work-hours-rubika -n 100' >&2; exit 1; }
echo "Installation complete. HTTP health check passed. Open http://SERVER_IP:$PORT (domain: $DOMAIN)."
echo 'No firewall or TLS rules were changed/configured. Set up HTTPS separately before exposing credentials.'
