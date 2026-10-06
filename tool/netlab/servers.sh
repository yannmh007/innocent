#!/usr/bin/env bash
# Real servers for the Local Network core — the ones people actually run at
# home: Samba (as Windows/NAS stand-in, SMB2/3 and an SMB1-only one), vsftpd
# (FTP, FTPS explicit with TLS-session-reuse REQUIRED, FTPS implicit) and
# OpenSSH (SFTP, password and key). Used by `gradle test` here and by the
# device lab, whose emulator reaches them at 10.0.2.2.
#
#   sudo tool/netlab/servers.sh start   [state dir, default /tmp/netlab]
#   sudo tool/netlab/servers.sh stop
#
# Ports (unprivileged where the server allows it):
#   SMB  445  (SMB2/3, the real port — the app's default; Scan looks there)
#   SMB1 4451 (NT1 only: an old router's USB share)
#   FTP  2121   FTPS explicit 2122   FTPS implicit 9900   SFTP 2222
# Account: netlab / netlab-pass. Anonymous: SMB share "public", FTP 2121.
set -euo pipefail
cmd=${1:-start}
S=${2:-/tmp/netlab}
USER_NAME=netlab
USER_PASS=netlab-pass

stop() {
  for p in "$S"/run/*.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null || true; done
  for pid in $(pgrep -f "$S/" || true); do
    [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ] && kill "$pid" 2>/dev/null || true
  done
}

if [ "$cmd" = stop ]; then stop; exit 0; fi
stop
sleep 1
rm -rf "$S"
mkdir -p "$S"/{run,media,smb1,smb2,ftp-anon,log,keys}

# ── the account ─────────────────────────────────────────────────────────
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$USER_NAME"
fi
echo "$USER_NAME:$USER_PASS" | chpasswd

# ── the media: the names that break naive clients ────────────────────────
M="$S/media"
mkdir -p "$M/Movies/Sub dir" "$M/Music" "$M/Empty"
head -c 6000000 /dev/urandom > "$M/Movies/film.mkv"
cp "$M/Movies/film.mkv" "$M/Movies/Sub dir/space name.mp4"
head -c 300000 /dev/urandom > "$M/Movies/Sub dir/ငါ့ဇာတ်ကား.mp4"
printf '1\n00:00:01,000 --> 00:00:02,000\nhello\n' > "$M/Movies/film.srt"
head -c 1000 /dev/urandom > "$M/Music/song.mp3"
# A GBK-named file, as a Chinese-locale FTP server stores it.
python3 -c "import os,sys; open(os.path.join(sys.argv[1], '中文.mp4'.encode('gbk')), 'wb').write(b'x'*1234)" "$M/Movies" 2>/dev/null \
  || python3 -c "import os,sys; open(os.fsencode(sys.argv[1]) + b'/' + '中文.mp4'.encode('gbk'), 'wb').write(b'x'*1234)" "$M/Movies"
# A real, playable video for the device lab (if ffmpeg is around).
if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -y -f lavfi -i testsrc=size=640x360:rate=25 -f lavfi -i sine=f=440 \
    -t 8 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$M/Movies/clip.mp4" || true
fi
chmod a+rx "$S"
chmod -R a+rX "$M"
chown -R "$USER_NAME" "$M"

# ── Samba ───────────────────────────────────────────────────────────────
smbconf() { # $1 dir  $2 port  $3 min  $4 max
  cat > "$1/smb.conf" <<EOF
[global]
  workgroup = WORKGROUP
  netbios name = NETLAB$2
  server role = standalone server
  smb ports = $2
  server min protocol = $3
  server max protocol = $4
  map to guest = Bad User
  guest account = nobody
  restrict anonymous = 0
  ntlm auth = yes
  lanman auth = no
  disable netbios = no
  load printers = no
  printing = bsd
  printcap name = /dev/null
  disable spoolss = yes
  log file = $1/log.%m
  private dir = $1/private
  lock directory = $1/lock
  state directory = $1/state
  cache directory = $1/cache
  pid directory = $1/pid
  ncalrpc dir = $1/ncalrpc
  passdb backend = tdbsam:$1/private/passdb.tdb
  # Every IPv4 address, explicitly: containers and CI runners often have
  # no IPv6, and smbd's default [::] bind then fails outright.
  interfaces = $V4
  bind interfaces only = yes
[public]
  path = $M
  guest ok = yes
  read only = yes
  browseable = yes
[private]
  path = $M
  valid users = $USER_NAME
  read only = yes
  browseable = yes
EOF
  mkdir -p "$1"/{private,lock,state,cache,pid,ncalrpc}
  printf '%s\n%s\n' "$USER_PASS" "$USER_PASS" | smbpasswd -c "$1/smb.conf" -s -a "$USER_NAME" >/dev/null
  smbd -D -s "$1/smb.conf"
  # The NetBIOS name service (UDP 137) answers Scan's "what is your name?".
  mkdir -p /run/samba/nmbd
  [ "$2" = 445 ] && nmbd -D -s "$1/smb.conf" || true
}
V4="127.0.0.1 $( { hostname -I 2>/dev/null || true; } | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | tr '\n' ' ' || true)"
smbconf "$S/smb2" 445 SMB2_02 SMB3
smbconf "$S/smb1" 4451 NT1 NT1

# ── vsftpd ──────────────────────────────────────────────────────────────
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=netlab" \
  -keyout "$S/keys/ftps.key" -out "$S/keys/ftps.pem" 2>/dev/null
mkdir -p /var/run/vsftpd/empty
cp -a "$M/." "$S/ftp-anon/" 2>/dev/null || true
chown -R root:root "$S/ftp-anon"; chmod 555 "$S/ftp-anon"
vsconf() { # $1 name $2 port $3 extra
  cat > "$S/run/$1.conf" <<EOF
listen=YES
listen_port=$2
background=YES
anonymous_enable=YES
anon_root=$S/ftp-anon
no_anon_password=YES
local_enable=YES
local_root=$M
chroot_local_user=YES
allow_writeable_chroot=YES
write_enable=NO
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
pasv_promiscuous=NO
seccomp_sandbox=NO
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
xferlog_enable=YES
vsftpd_log_file=$S/log/$1.log
utf8_filesystem=NO
$3
EOF
  vsftpd "$S/run/$1.conf"
}
TLS="ssl_enable=YES
rsa_cert_file=$S/keys/ftps.pem
rsa_private_key_file=$S/keys/ftps.key
allow_anon_ssl=YES
force_local_data_ssl=YES
force_local_logins_ssl=YES
require_ssl_reuse=YES
ssl_ciphers=HIGH"
vsconf ftp 2121 ""
vsconf ftps 2122 "$TLS"
vsconf ftpsi 9900 "$TLS
implicit_ssl=YES"

# ── OpenSSH (SFTP) ─────────────────────────────────────────────────────
ssh-keygen -q -t ed25519 -N '' -f "$S/keys/host_ed25519" <<<y >/dev/null 2>&1 || true
ssh-keygen -q -t ed25519 -N '' -C netlab -f "$S/keys/user_ed25519" <<<y >/dev/null 2>&1 || true
ssh-keygen -q -t rsa -b 2048 -m PEM -N 'key-pass' -C netlab -f "$S/keys/user_rsa" <<<y >/dev/null 2>&1 || true
H=$(getent passwd "$USER_NAME" | cut -d: -f6)
# SFTP starts in the account's home: put the media one folder in.
ln -sfn "$M" "$H/media"
mkdir -p "$H/.ssh"
cat "$S/keys/user_ed25519.pub" "$S/keys/user_rsa.pub" > "$H/.ssh/authorized_keys"
chown -R "$USER_NAME" "$H/.ssh"; chmod 700 "$H/.ssh"; chmod 600 "$H/.ssh/authorized_keys"
mkdir -p /run/sshd
cat > "$S/run/sshd.conf" <<EOF
Port 2222
HostKey $S/keys/host_ed25519
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
PidFile $S/run/sshd.pid
Subsystem sftp internal-sftp
EOF
/usr/sbin/sshd -f "$S/run/sshd.conf"

chmod a+r "$S"/keys/user_* "$S/keys/ftps.pem"
sleep 1
echo "netlab servers up in $S"
