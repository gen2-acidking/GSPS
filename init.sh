#!/usr/bin/env bash
# init.sh – GSPS bootstrap (minimal edition)
# turns the *existing* repo folder into a local Gentoo mirror

set -euo pipefail

########################################################################
#                     DEFAULT CONFIG (override via config.sh)          #
########################################################################
REPO_ROOT="$(pwd)"                 
LOCAL_IP="192.168.122.38"          # nginx bind address  
PROVISIONER_IP="192.168.0.103"     # upstream GSPS for --copy
INSTALL_MODE="copy"                # create | copy | test
TEST_MODE=false

[[ -f "./config.sh" ]] && source "./config.sh"

########################################################################
#                            LOGGING UTILS                             #
########################################################################
log() { echo "[$(date +'%H:%M:%S')] $*"; }

########################################################################
#                         CORE SYSTEM SETUP                            #
########################################################################
install_dependencies() {
  log "installing system packages"
  sudo mkdir -p /etc/portage/package.use

  sudo tee /etc/portage/package.use/git         <<< 'dev-vcs/git cgi'            >/dev/null
  sudo tee /etc/portage/package.use/mime-types  <<< 'app-misc/mime-types nginx'  >/dev/null
  sudo tee /etc/portage/package.use/nginx       <<< 'www-servers/nginx http2 ssl' >/dev/null

  sudo emerge --ask=n         \
    app-misc/mime-types       \
    dev-vcs/git               \
    www-servers/nginx         \
    www-misc/fcgiwrap         \
    www-servers/spawn-fcgi    \
    net-misc/rsync
}

########################################################################
#                   INITIALIZE EXISTING FOLDERS ONLY                   #
########################################################################
initialize_writable_folders() {
  log "Making portage/ and distfiles/ writable by nginx"
  sudo chown -R nginx:nginx ./portage ./distfiles
  sudo chmod -R 755 ./portage ./distfiles

  sudo chmod g+w .
  sudo chgrp nginx .
}

########################################################################
#                          DATA SYNCHRONISATION                        #
########################################################################
simplified_test_mode() {
  log "TEST mode skipping sync"
  echo "Test mode repositories not synced" | sudo -u nginx tee ./README.test >/dev/null
}

sync_from_master() {
  sudo -u nginx git clone --bare --depth 1 \
       https://github.com/gentoo-mirror/gentoo.git \
       ./portage/gentoo.git

  log "Syncing distfiles from rsync://masterdistfiles.gentoo.org (long run)"
  sudo -u nginx rsync --recursive --links --safe-links --perms --times \
                      --omit-dir-times --delete --stats --human-readable \
                      --progress --timeout=180 \
                      rsync://masterdistfiles.gentoo.org/gentoo/distfiles/ \
                      ./distfiles/
}

copy_from_existing() {
  log "Copying trees from upstream GSPS ${PROVISIONER_IP}"
  sudo -u nginx rsync -avz --delete \
       "rsync://${PROVISIONER_IP}/portage"  ./portage
  sudo -u nginx rsync -avz --delete \
       "rsync://${PROVISIONER_IP}/distfiles" ./distfiles
}

########################################################################
#                       SERVICE CONFIGURATION                          #
########################################################################
setup_nginx() {
  log "Writing nginx.conf"
  sudo tee /etc/nginx/nginx.conf >/dev/null <<EOF
user  nginx nginx;
worker_processes auto;

events { worker_connections 1024; use epoll; }

http {
    include /etc/nginx/mime.types.nginx;
    types_hash_max_size 4096;
    default_type application/octet-stream;

    server {
        listen ${LOCAL_IP}:80 default_server;
        server_name repo.local localhost;
        root ${REPO_ROOT};

        access_log /var/log/nginx/access.log;
        error_log  /var/log/nginx/error.log info;

        location = /provision.sh { add_header Content-Type text/plain; try_files \$uri =404; }
        location = /init.sh      { add_header Content-Type text/plain; try_files \$uri =404; }

        location /scripts/   { alias ${REPO_ROOT}/scripts/;   autoindex on; }
        location /configs/   { alias ${REPO_ROOT}/configs/;   autoindex on; }
        location /resources/ { alias ${REPO_ROOT}/resources/; autoindex on; }
        location /distfiles/ { alias ${REPO_ROOT}/distfiles/; autoindex on; }
      

        location ~ ^/portage(/.*)\$ {
            include fastcgi_params;
            fastcgi_pass unix:/run/fcgiwrap.sock-1;
            fastcgi_param SCRIPT_FILENAME /usr/libexec/git-core/git-http-backend;
            fastcgi_param GIT_PROJECT_ROOT ${REPO_ROOT}/portage;
            fastcgi_param GIT_HTTP_EXPORT_ALL "";
            fastcgi_param PATH_INFO \$1;
        }

        location ~ ^/overlays(/.*)\$ {
            include fastcgi_params;
            fastcgi_pass unix:/run/fcgiwrap.sock-1;
            fastcgi_param SCRIPT_FILENAME /usr/libexec/git-core/git-http-backend;
            fastcgi_param GIT_PROJECT_ROOT ${REPO_ROOT}/overlays;
            fastcgi_param GIT_HTTP_EXPORT_ALL "";
            fastcgi_param PATH_INFO \$1;
        }
    }
}
EOF
  sudo rc-service nginx restart 2>/dev/null || sudo systemctl restart nginx.service || true
  log "nginx restarted"
}

setup_fcgiwrap() {
  log "Setting up fcgiwrap socket + service"
  sudo mkdir -p /etc/init.d /run

  sudo tee /etc/init.d/fcgiwrap >/dev/null <<'EOS'
#!/sbin/openrc-run
command=/usr/sbin/spawn-fcgi
command_args="-s /run/fcgiwrap.sock-1 -M 766 -u nginx -g nginx /usr/sbin/fcgiwrap"
pidfile=/run/fcgiwrap.pid
depend() { need net ; }
EOS
  sudo chmod +x /etc/init.d/fcgiwrap

  if pidof systemd >/dev/null 2>&1; then
    sudo tee /etc/systemd/system/fcgiwrap.socket >/dev/null <<'EOS'
[Unit]
Description=fcgiwrap Socket

[Socket]
ListenStream=/run/fcgiwrap.sock-1
SocketUser=nginx
SocketGroup=nginx
SocketMode=0666

[Install]
WantedBy=sockets.target
EOS
    sudo tee /etc/systemd/system/fcgiwrap.service >/dev/null <<'EOS'
[Unit]
Description=Simple CGI Server

[Service]
ExecStart=/usr/sbin/fcgiwrap
User=nginx
Group=nginx

[Install]
WantedBy=multi-user.target
EOS
    sudo systemctl daemon-reload
    sudo systemctl enable --now fcgiwrap.socket fcgiwrap.service >/dev/null
  else
    sudo rc-service fcgiwrap restart || sudo rc-service fcgiwrap start
  fi
  log "fcgiwrap running"
}

setup_rsync() {
  log "Configuring local rsync daemon"
  sudo mkdir -p /etc/rsync
  sudo tee /etc/rsync/rsyncd.conf >/dev/null <<EOF
pid file       = /run/rsyncd.pid
max connections= 5
use chroot     = yes
uid            = nobody
gid            = nobody
read only      = yes

[gentoo-portage]
  path    = ${REPO_ROOT}/portage
  comment = Gentoo Portage tree

[gentoo-distfiles]
  path    = ${REPO_ROOT}/distfiles
  comment = Distfiles cache
EOF
  sudo rc-service rsyncd restart 2>/dev/null || \
       sudo systemctl restart rsyncd.service 2>/dev/null || \
       sudo systemctl restart rsync.service 2>/dev/null || true
  log "rsync daemon started"
}

enable_services() {
  if command -v rc-update >/dev/null; then
    sudo rc-update add nginx default
    sudo rc-update add fcgiwrap default
    sudo rc-update add rsyncd default
  elif command -v systemctl >/dev/null; then
    sudo systemctl enable nginx.service
    sudo systemctl enable fcgiwrap.socket fcgiwrap.service
    sudo systemctl enable rsyncd.service || sudo systemctl enable rsync.service || true
  fi
}

########################################################################
#                                MAIN                                  #
########################################################################
while [[ $# -gt 0 ]]; do
  case $1 in
    --create) INSTALL_MODE="create" ;;
    --copy)   INSTALL_MODE="copy" ;;
    --test)   INSTALL_MODE="test"; TEST_MODE=true ;;
    --help|-h)
      echo "Usage: $0 [--create | --copy | --test]"; exit 0 ;;
    *)
      echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

log "== GSPS bootstrap =="
log "Mode: ${INSTALL_MODE}"
log "Doc-root: ${REPO_ROOT}"

install_dependencies
initialize_writable_folders

case ${INSTALL_MODE} in
  create) sync_from_master ;;
  copy)   copy_from_existing ;;
  test)   simplified_test_mode ;;
esac

setup_fcgiwrap
setup_nginx
setup_rsync
enable_services

log "🎉  GSPS ready at http://${LOCAL_IP}/ (Portage & distfiles served)"
