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

# Create the PAM access check
cat > /etc/pam.d/sshd << 'EOF'
# Standard Debian SSH PAM
@include common-auth
@include common-account
@include common-session
@include common-password

# LXC access control: only users in /etc/lxc-access.conf can log in
account required pam_listfile.so item=user sense=allow file=/etc/lxc-access.conf onerr=fail
EOF

touch /etc/lxc-access.conf
chmod 644 /etc/lxc-access.conf

echo "=== Configuring SSH ==="
cat > /etc/ssh/ssh_config << 'EOF'
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
MaxSessions 1
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
KbdInteractiveAuthentication yes
AuthorizedKeysCommand /usr/local/bin/ldap-ssh-keys.sh %u
AuthorizedKeysCommandUser root
EOF

echo "=== Importing user SSH keys from Authentik ==="
cat > /usr/local/bin/ldap-ssh-keys.sh << EOF
#!/bin/bash
# Exit immediately if no username is provided
if [ -z "\$1" ]; then
    exit 1
fi

# Configuration - Change to match your authentik environment
LDAP_URI="ldap://${LDAP_SERVER}:389"
BASE_DN="${LDAP_BASE_DN}"
# If your authentik LDAP provider requires search binding, add bind credentials here:
BIND_DN="${LDAP_BIND_DN}"
BIND_PASS="${LDAP_BIND_PW}"


# Execute search and capture stderr to see what is breaking
RAW_OUTPUT=\$(ldapsearch -x -H "\$LDAP_URI" \
                        -D "\$BIND_DN" \
                        -w "\$BIND_PASS" \
                        -b "\$BASE_DN" \
                        "(cn=\$1)" \
                        ssh_public_key 2>&1)

# Check if ldapsearch threw an explicit connection error
if [[ "\$RAW_OUTPUT" =~ "Can't contact LDAP server" ]] || [[ "\$RAW_OUTPUT" =~ "Invalid credentials" ]]; then
    echo "DEBUG ERROR: ldapsearch failed inside the script context!" >&2
    echo "\$RAW_OUTPUT" >&2
    exit 1
fi

# Cleanly isolate the multi-line key block and format it onto one line
echo "\$RAW_OUTPUT" | awk '
    BEGIN { found=0 }
    /^ssh_public_key: / { sub(/^ssh_public_key: /, ""); printf "%s", \$0; found=1; next }
    /^[ ]/ && found { sub(/^[ ]/, ""); printf "%s", \$0; next }
    /^[a-zA-Z]/ || /^$/ { if (found) { exit } }
'
echo "" # Ensure structural trailing newline for OpenSSH
EOF

chmod +x /usr/local/bin/ldap-ssh-keys.sh
chown root:root /usr/local/bin/ldap-ssh-keys.sh
chmod 755 /usr/local/bin/ldap-ssh-keys.sh

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

echo "=== Fixing Global System PATH for standard users ==="
cat >> /etc/profile << 'EOF'

# Append administrative paths so standard users can execute non-sudo binaries
if [ "$(id -u)" -ne 0 ]; then
    export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
fi
EOF

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
systemctl restart nslcd
systemctl restart ssh

echo "=== Cleaning up ==="
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /root/.bash_history
history -c

echo ""
echo "=== Template preparation complete ==="
echo "Set these env vars before cloning:"
echo "  LDAP_SERVER, LDAP_BASE_DN, LDAP_BIND_DN, LDAP_BIND_PW"