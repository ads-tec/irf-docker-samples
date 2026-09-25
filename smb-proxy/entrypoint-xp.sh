#!/bin/sh
set -e

# Create XP share user
adduser -D -H xpuser 2>/dev/null || true
echo -e "${XP_PASSWORD:-xppass123}\n${XP_PASSWORD:-xppass123}" | smbpasswd -a -s xpuser

# Create some test files
mkdir -p /share
echo "This is a test file from the XP simulator." > /share/testfile.txt
echo "Another test document." > /share/document.txt
mkdir -p /share/subfolder
echo "File in subfolder." > /share/subfolder/nested.txt

# Fix permissions
chown -R xpuser:xpuser /share

echo "=== XP Simulator starting (SMBv1 on port 445) ==="
exec smbd --foreground --no-process-group --configfile=/etc/samba/smb.conf
