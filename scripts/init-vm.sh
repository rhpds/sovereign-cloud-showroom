#!/bin/bash
sudo dnf clean all
sudo dnf update -y
# Install additional packages for security demo (commonly flagged in vulnerability scans)
sudo dnf install -y \
  httpd curl wget openssl openssl-libs zlib libxml2 \
  ghostscript perl nginx tar gzip nmap-ncat bzip2 zip unzip \
  freetype libjpeg-turbo libtiff libpng gnutls 2>/dev/null || true
# Download the latest roxagent binary; run every 10 minutes via /etc/cron.d (no systemd unit required)
curl -L -f -o /tmp/roxagent https://mirror.openshift.com/pub/rhacs/assets/4.10.0/bin/linux/roxagent
chmod +x /tmp/roxagent
sudo mv /tmp/roxagent /usr/local/bin/roxagent
sudo restorecon -v /usr/local/bin/roxagent
printf '%s\n' \
  'SHELL=/bin/bash' \
  'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  'MAILTO=root' \
  '# Run roxagent every 10 minutes as root' \
  '*/10 * * * * root /usr/local/bin/roxagent --daemon' \
| sudo tee /etc/cron.d/roxagent > /dev/null
sudo chmod 644 /etc/cron.d/roxagent
sudo restorecon -vF /etc/cron.d/roxagent
sudo systemctl restart crond
 
