#!/bin/bash
# Setup script for Debian 13 LXC template with authentik-agent

set -euo pipefail

AUTHENTIK_URL="${AUTHENTIK_URL:-https://authentik.example.com}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-pve-lxc}"

echo "=== Installing authentik-agent repository ==="
curl -fsSL https://pkg.goauthentik.io/keys/gpg-key.asc | gpg --dearmor -o /usr/share/keyrings/authentik-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/authentik-keyring.gpg] https://pkg.goauthentik.io stable main" > /etc/apt/sources.list.d/authentik.list

echo "=== Updating system ==="
apt-get update
apt-get upgrade -y

echo "=== Installing authentik agent packages ==="
apt-get install -y \
    authentik-cli \
    authentik-agent \
    authentik-sysd \
    libnss-authentik \
    libpam-authentik \
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
    apt-transport-https \
    gnupg \
    systemd-timesyncd

echo "=== Configuring NSS for authentik ==="
cat > /etc/nsswitch.conf << 'EOF'
passwd:         files systemd authentik
group:          files systemd authentik
shadow:         files systemd authentik
gshadow:        files systemd
hosts:          files dns
networks:       files
protocols:      db files
services:       db files
ethers:         db files
rpc:            db files
netgroup:       nis
EOF

echo "=== Configuring PAM for authentik ==="
if ! grep -q "pam_authentik.so" /etc/pam.d/common-auth 2>/dev/null; then
    sed -i '/^auth.*pam_unix.so/i auth    [success=2 default=ignore]      pam_authentik.so' /etc/pam.d/common-auth
fi
if ! grep -q "pam_authentik.so" /etc/pam.d/common-session 2>/dev/null; then
    sed -i '/^session.*pam_unix.so/a session required                        pam_authentik.so' /etc/pam.d/common-session
fi
if ! grep -q "pam_authentik.so" /etc/pam.d/common-account 2>/dev/null; then
    sed -i '/^account.*pam_unix.so/i account    [success=2 default=ignore]     pam_authentik.so' /etc/pam.d/common-account
fi

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
ChallengeResponseAuthentication yes
UsePAM yes
AllowUsers *
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
EOF

echo "=== Creating sudo rules ==="
cat > /etc/sudoers.d/99-admins << 'EOF'
%Administrators ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/99-admins

cat > /etc/sudoers.d/98-lectors << 'EOF'
%Lectors ALL=(ALL) NOPASSWD: /bin/systemctl restart apache2, /bin/systemctl restart nginx
%Lectors ALL=(ALL) NOPASSWD: /bin/systemctl restart mysql, /bin/systemctl restart postgresql
%Lectors ALL=(ALL) NOPASSWD: /bin/systemctl restart php*-fpm
%Lectors ALL=(ALL) NOPASSWD: /bin/systemctl status *
%Lectors ALL=(ALL) NOPASSWD: /usr/sbin/useradd *, /usr/sbin/usermod *
%Lectors ALL=(ALL) !NOPASSWD: /usr/sbin/userdel akadmin, !/usr/sbin/userdel lector*
%Lectors ALL=(ALL) !NOPASSWD: /usr/sbin/usermod -G *Administrators*, !/usr/sbin/usermod -G *Lectors*
%Lectors ALL=(ALL) NOPASSWD: /bin/chown * /home/*, /bin/chmod * /home/*
%Lectors ALL=(ALL) NOPASSWD: /bin/chown * /var/www/*, /bin/chmod * /var/www/*
EOF
chmod 0440 /etc/sudoers.d/98-lectors

cat > /etc/sudoers.d/97-students << 'EOF'
%Students ALL=(ALL) NOPASSWD: /bin/chown * /home/*, /bin/chmod * /home/*
%Students ALL=(ALL) NOPASSWD: /bin/chown * /var/www/*, /bin/chmod * /var/www/*
%Students ALL=(ALL) NOPASSWD: /bin/systemctl restart apache2, /bin/systemctl restart nginx
%Students ALL=(ALL) NOPASSWD: /bin/systemctl restart php*-fpm
%Students ALL=(ALL) NOPASSWD: /bin/systemctl status *
%Students ALL=(ALL) !NOPASSWD: /bin/systemctl stop *, /bin/systemctl disable *
%Students ALL=(ALL) !NOPASSWD: /bin/systemctl kill *
%Students ALL=(ALL) !NOPASSWD: /usr/sbin/userdel root, /usr/sbin/userdel akadmin
%Students ALL=(ALL) !NOPASSWD: /usr/sbin/userdel lector*, /usr/sbin/usermod lector*
%Students ALL=(ALL) !NOPASSWD: /usr/sbin/userdel *admin*, /usr/sbin/usermod *admin*
%Students ALL=(ALL) !NOPASSWD: /usr/sbin/usermod -aG sudo *, /usr/sbin/usermod -aG root *
%Students ALL=(ALL) !NOPASSWD: /usr/sbin/usermod -aG Administrators *, /usr/sbin/usermod -aG Lectors *
%Students ALL=(ALL) NOPASSWD: /usr/bin/apt install *, /usr/bin/apt-get install *
%Students ALL=(ALL) !NOPASSWD: /usr/bin/apt remove *systemd*, /usr/bin/apt remove *ssh*
%Students ALL=(ALL) !NOPASSWD: /usr/bin/apt purge *systemd*, /usr/bin/apt purge *ssh*
%Students ALL=(ALL) !NOPASSWD: /usr/bin/vim /etc/sudoers*, /usr/bin/nano /etc/sudoers*
%Students ALL=(ALL) !NOPASSWD: /bin/rm /etc/sudoers*, /bin/mv /etc/sudoers*
EOF
chmod 0440 /etc/sudoers.d/97-students

visudo -c

cat > /etc/ssh/banner << 'EOF'
***************************************************************************
*                     PROXMOX AUTHENTIK HOSTING PLATFORM                  *
*                                                                         *
*  Authorized access only. All activity may be monitored and recorded.    *
*  Access controlled by authentik device policies.                        *
***************************************************************************
EOF

mkdir -p /etc/skel/.ssh
chmod 700 /etc/skel/.ssh

systemctl enable ssh
systemctl enable authentik-sysd

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /root/.bash_history
history -c

echo ""
echo "=== Template preparation complete ==="
echo "Do NOT enroll to authentik. The clones will enroll individually."