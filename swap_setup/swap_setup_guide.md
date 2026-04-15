# SWAP Setup Guide for HestiaCP

When running HestiaCP on servers with low RAM (like 1GB or 2GB), creating a SWAP file is essential to prevent out-of-memory (OOM) errors. SWAP acts as virtual memory, keeping your services (like MariaDB and PHP) running smoothly during traffic spikes.

## Recommended SWAP Sizes

| Server RAM | Recommended SWAP Size |
|------------|-----------------------|
| 1GB        | 2GB                   |
| 2GB        | 2GB or 4GB            |
| 4GB        | 4GB                   |
| 8GB+       | 4GB (or none)         |

---

## 🚀 1-Click Setup Script (Copy & Paste)

This script automatically creates a **2GB SWAP file**, sets the correct permissions, enables it, and makes it permanent across reboots.

Run this as `root`:

```bash
# 1. Create a 2GB swap file
fallocate -l 2G /swapfile

# If fallocate fails (common on some VPS providers), use dd instead:
# dd if=/dev/zero of=/swapfile bs=1024 count=2097152

# 2. Set the correct permissions (CRITICAL for security)
chmod 600 /swapfile

# 3. Format the file as swap
mkswap /swapfile

# 4. Enable the swap file
swapon /swapfile

# 5. Make it permanent (adds to /etc/fstab)
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

# 6. Verify it's working
free -h
```

---

## ⚙️ Tuning Swappiness (Optional but Recommended)

By default, Linux has a "swappiness" value of `60`, which might use the SWAP file too aggressively. For servers hosting web applications (like HestiaCP), a value of `10` is generally better, as it tells the system to use physical RAM as much as possible before relying on SWAP.

**To check your current swappiness:**
```bash
cat /proc/sys/vm/swappiness
```

**To change it to `10`:**
```bash
# Apply immediately
sysctl vm.swappiness=10

# Make it permanent across reboots
echo 'vm.swappiness=10' | tee -a /etc/sysctl.conf
```

---

## 🗑️ How to Remove SWAP

If you ever upgrade your server and no longer need the SWAP file, follow these steps to safely remove it:

```bash
# 1. Disable the swap file
swapoff -v /swapfile

# 2. Remove the swap file entry from /etc/fstab
nano /etc/fstab
# (Delete the line that says: /swapfile none swap sw 0 0)

# 3. Delete the actual file
rm -f /swapfile
```
