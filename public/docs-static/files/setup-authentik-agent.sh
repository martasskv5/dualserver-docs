#!/bin/bash
# Setup script for Debian 13 LXC template
# Uses libnss-ldapd + libpam-ldapd with authentik LDAP outpost (FREE)
# Drops libnss-authentik/libpam-authentik (requires Enterprise license for password auth)

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

LDAP_SERVER="${LDAP_SERVER:-authentik.mgmt.pve99.local}"
LDAP_BASE_DN="${LDAP_BASE_DN:-DC=authentik,DC=mgmt,DC=pve99,DC=local}"
LDAP_BIND_DN="${LDAP_BIND_DN:-CN=ldap-bind-account,DC=authentik,DC=mgmt,DC=pve99,DC=local}"
LDAP_BIND_PW="${LDAP_BIND_PW:-c0nw3nP04JbH3rIo6oWO0ZIoZyJW9ndu0kNAIxsZQwl2aAT2l7YYOMJoAonT}"

echo "=== Updating system ==="
apt-get update
apt-get upgrade -y

echo "=== Installing LDAP client packages ==="
apt-get install -y \
    libnss-ldapd \
    libpam-ldapd \
    nslcd \
    ldap-utils \
    sudo \
    ssh \
    curl \
    wget \
    vim \
    htop \
    net-tools \
    iputils-ping \
    dnsutils \
    ca-certificates \
    mc

echo "=== Configuring nslcd ==="
cat > /etc/nslcd.conf << EOF
uid root
gid root
uri ldap://${LDAP_SERVER}:389
base ${LDAP_BASE_DN}
binddn ${LDAP_BIND_DN}
bindpw ${LDAP_BIND_PW}

base passwd ou=users,${LDAP_BASE_DN}
base group ou=groups,${LDAP_BASE_DN}

# Authentik uses generic objectClasses
filter passwd (objectClass=user)
filter group (objectClass=group)

# Crucial mappings for authentik schema
map passwd uid sAMAccountName
map passwd uidNumber uidNumber
map passwd gidNumber gidNumber
map passwd homeDirectory "/home/\$sAMAccountName"
map passwd loginShell "/bin/bash"

map group cn cn
map group gidNumber gidNumber
map group memberUid member
EOF
chmod 600 /etc/nslcd.conf

echo "=== Configuring NSS ==="
cat > /etc/nsswitch.conf << 'EOF'
passwd:         files ldap
group:          files ldap
shadow:         files ldap
gshadow:        files
hosts:          files dns
networks:       files
protocols:      db files
services:       db files
ethers:         db files
rpc:            db files
netgroup:       nis
EOF

echo "=== Configuring PAM cleanly ==="
# Update the PAM profiles to explicitly enable LDAP and home-directory creation
pam-auth-update --package --enable ldap mkhomedir

echo "=== Configuring SSH ==="
cat > /etc/ssh/sshd_config << 'EOF'
Port 22
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
Banner /etc/ssh/banner
SyslogFacility AUTH
LogLevel INFO
MaxSessions 10
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
KbdInteractiveAuthentication yes
EOF

echo "=== Creating sudo rules ==="

# 1. Secure Administrators Block (Keeps full access)
cat > /etc/sudoers.d/99-admins << 'EOF'
%Administrators ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/99-admins

# 2. Secure Lectors Block
cat > /etc/sudoers.d/98-lectors << 'EOF'
# Prevent systemctl from spawning a paginated root viewer shell
Defaults:%Lectors env_keep += "SYSTEMD_PAGER=cat"

Cmnd_Alias LECTOR_RESTART = /bin/systemctl restart apache2, /bin/systemctl restart nginx, /bin/systemctl restart angie, /bin/systemctl restart mysql, /bin/systemctl restart postgresql, /bin/systemctl restart php*-fpm
Cmnd_Alias LECTOR_STATUS = /bin/systemctl status [A-Za-z0-9_-]*
Cmnd_Alias LECTOR_USERMGMT = /usr/sbin/useradd [A-Za-z0-9_-]*, /usr/sbin/usermod [A-Za-z0-9_-]*
Cmnd_Alias LECTOR_FILE_PERMS = /bin/chown [A-Za-z0-9_-]* /home/*, /bin/chmod * /home/*, /bin/chown [A-Za-z0-9_-]* /var/www/*, /bin/chmod * /var/www/*
Cmnd_Alias LECTOR_DENY = /usr/sbin/userdel akadmin, /usr/sbin/userdel lector*, /usr/sbin/usermod *-G*

%Lectors ALL=(ALL) NOPASSWD: LECTOR_RESTART, LECTOR_STATUS, LECTOR_USERMGMT, LECTOR_FILE_PERMS, !LECTOR_DENY
EOF
chmod 0440 /etc/sudoers.d/98-lectors

# 3. Secure Students Block
cat > /etc/sudoers.d/97-students << 'EOF'
# Force strict limitations on text pagers for student runs
Defaults:%Lectors env_keep += "SYSTEMD_PAGER=cat"

Cmnd_Alias STUDENT_WEB_RESTART = /bin/systemctl restart apache2, /bin/systemctl restart nginx, /bin/systemctl restart angie, /bin/systemctl restart php*-fpm
Cmnd_Alias STUDENT_STATUS = /bin/systemctl status [A-Za-z0-9_-]*
Cmnd_Alias STUDENT_FILE_PERMS = /bin/chown [A-Za-z0-9_-]* /home/*, /bin/chmod * /home/*, /bin/chown [A-Za-z0-9_-]* /var/www/*, /bin/chmod * /var/www/*

# Limit apt inputs to standard single alphanumeric package strings instead of catching all characters (*)
Cmnd_Alias STUDENT_INSTALL = /usr/bin/apt install [A-Za-z0-9_-]*, /usr/bin/apt-get install [A-Za-z0-9_-]*

# Strict system level denial groupings
Cmnd_Alias STUDENT_DENY_SYS = /bin/systemctl stop *, /bin/systemctl disable *, /bin/systemctl kill *, /usr/sbin/userdel *, /usr/sbin/usermod *
Cmnd_Alias STUDENT_DENY_PKG = /usr/bin/apt remove *, /usr/bin/apt-get remove *, /usr/bin/apt purge *, /usr/bin/apt-get purge *

%Students ALL=(ALL) NOPASSWD: STUDENT_WEB_RESTART, STUDENT_STATUS, STUDENT_FILE_PERMS, STUDENT_INSTALL, !STUDENT_DENY_SYS, !STUDENT_DENY_PKG
EOF
chmod 0440 /etc/sudoers.d/97-students

visudo -c

cat > /etc/ssh/banner << 'EOF'
***************************************************************************
*                     PROXMOX AUTHENTIK HOSTING PLATFORM                  *
*                                                                         *
*  Authorized access only. All activity may be monitored and recorded.    *
*  Access controlled by authentik LDAP groups.                            *
***************************************************************************
EOF

mkdir -p /etc/skel/.ssh
chmod 700 /etc/skel/.ssh

echo "=== Enabling services ==="
systemctl enable nslcd
systemctl enable ssh

echo "=== Cleaning up ==="
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /root/.bash_history
history -c

echo ""
echo "=== Template preparation complete ==="
echo "Set these env vars before cloning:"
echo "  LDAP_SERVER, LDAP_BASE_DN, LDAP_BIND_DN, LDAP_BIND_PW"