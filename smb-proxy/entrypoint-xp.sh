#!/bin/sh
set -e

# No default password: XP_PASSWORD must be set explicitly
if [ -z "${XP_PASSWORD:-}" ]; then
    echo "ERROR: XP_PASSWORD is not set (password of xpuser on the simulated share)" >&2
    exit 1
fi

# Create XP share user
adduser -D -H xpuser 2>/dev/null || true
printf '%s\n%s\n' "${XP_PASSWORD}" "${XP_PASSWORD}" | smbpasswd -a -s xpuser

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
