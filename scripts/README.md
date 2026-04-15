# 📂 HestiaCP Scripts Directory

Welcome to the **HestiaCP Scripts** folder. This directory contains individual standalone mini-programs (modules) that you can install to supercharge your HestiaCP server. 

> **Amateur Friendly:** Every tool here comes with its own dummy-proof installer. You never need to copy loose files manually or mess with the kernel!

---

## 🛠️ Available Modules

Click on any module below to read its dedicated dummy-proof guide:

### 1. [clean-garbage](./clean-garbage/)
A housekeeper script. It safely deletes old logs, temp files, and spam emails to free up disk space on your server.

### 2. [backup-core-patches](./backup-core-patches/)
Upgrades the native HestiaCP backup engine. Automatically organizes your server backups into clean Yearly/Monthly folders (`YYYY/MM`), repairs corrupted databases before exporting them, and sends you modern Dark-Mode HTML emails instead of plain text.

### 3. [exim-limit](./exim-limit/)
A spam protector. Automatically blocks any outgoing emails larger than 10MB to prevent your server from being blacklisted by Google or Microsoft.

### 4. [fix-web-permissions](./fix-web-permissions/)
**⚠️ Powerful Tool:** Natively fixes broken `public_html` file ownerships (usually caused by FTP uploads) and hardens your WordPress/CMS security against hackers.

### 5. [security-audit](./security-audit/)
**⚠️ Powerful Tool:** A deep security scanner. Sweeps your server for Malware, vulnerabilities, open ports, and weak passwords, generating an "A to F" graded security report.

### 6. [system-report](./system-report/)
Sends you a beautiful HTML email report every morning showing your Server RAM, CPU usage, Disk Space, and service health.

### 7. [github-mirror](./github-mirror/)
Automates the cloning and syncing of your private GitHub repositories down to your server folders.

---

## 🚀 How to Install Everything (The Easy Way)

If you want to install ALL these tools at once, do not click into these folders. Just go back to the Root directory of this repository and run the master installer:

```bash
cd /root/hestiacp-useful-tools
bash install.sh
```

If you only want to install one specific tool, click its name in the list above and follow the instructions inside!
