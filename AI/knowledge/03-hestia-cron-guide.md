# HestiaCP Cron Jobs & Automation Guide

## 1. Verified System Paths (Consult `01-hestia-system-paths.md`)
**CRITICAL:** Cron jobs are split between Hestia users and system-wide configurations.

| Component | Path |
| :--- | :--- |
| **Hestia User Crons** | `/var/spool/cron/crontabs/[USER]` |
| **System Crontab** | `/etc/crontab` |
| **System Daily** | `/etc/cron.daily/` |
| **System Hourly** | `/etc/cron.hourly/` |
| **Cron Log** | `/var/log/syslog` (grep CRON) |

## 2. Managing Hestia User Crons
These are managed via the panel or CLI and run as the specific user.

### A. List Jobs
```bash
# Admin users
sudo -n /usr/local/hestia/bin/v-list-cron-jobs admin

# Specific user
sudo -n /usr/local/hestia/bin/v-list-cron-jobs USER
```

### B. Debugging Failures
1.  **Check Exit Code:**
    Hestia doesn't log stdout/stderr by default unless configured.
    Check `/var/log/syslog` for execution:
    ```bash
    sudo -n grep "CRON" /var/log/syslog | grep "USER" | tail -n 20
    ```

2.  **Manually Run a Job:**
    To test a job, run it as the user (NOT root):
    ```bash
    sudo -u USER bash -c "COMMAND"
    ```

## 3. Managing System Crons (Root)
These run as root and are critical for maintenance.

### A. List System Jobs
```bash
# Main crontab
sudo -n cat /etc/crontab

# Daily scripts
ls -l /etc/cron.daily/
```

### B. Installation-specific schedules

Do not assume a universal weekly schedule, cron account or custom backup wrapper. Inspect panel-managed jobs and system cron files on the selected installation; compare exact dates in the server timezone. Identify the installed native backup command, hooks and log locations before concluding that a run was missed. Repository mirroring is separate from knowledge snapshot maintenance.

## 4. Common issues

Check executable permissions, the cron user's environment and limited PATH, and the actual server timezone. Use absolute paths. Do not manually execute a backup or maintenance job during a read-only investigation.
