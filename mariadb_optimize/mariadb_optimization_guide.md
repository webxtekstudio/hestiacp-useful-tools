# MariaDB Performance Optimization Guide for HestiaCP

By default, MariaDB (the database server used by HestiaCP) is configured to use very little RAM. This is safe for tiny servers (1GB RAM) but causes massive performance bottlenecks on larger servers because the database has to constantly read from the slow disk instead of the fast RAM.

The single most important setting you can change to speed up your websites (especially WordPress/WooCommerce) is the **InnoDB Buffer Pool Size**.

---

## 1. What is the InnoDB Buffer Pool?

The buffer pool is where MariaDB caches table data and indexes in RAM. 
If your database is 2GB in size, and your buffer pool is only 128MB (the default), MariaDB has to constantly swap data in and out of the RAM to the disk. This causes high CPU usage, slow page loads, and high I/O wait times.

If you increase the buffer pool to hold your entire database in RAM, your database queries will execute almost instantly.

## 2. How to Calculate the Perfect Size

**The Golden Rule:** 
Set `innodb_buffer_pool_size` to **60% - 70% of your *available* RAM**, provided you have enough RAM left over for the OS and PHP-FPM.

### Scenario A: Small Server (2GB RAM)
- OS: ~500MB
- PHP/Web: ~1GB
- Available for DB: ~500MB
- **Recommended Setting:** `innodb_buffer_pool_size = 256M` or `512M`

### Scenario B: Medium Server (8GB RAM) - Typical Agency Setup
- OS: ~1GB
- PHP/Web (Ondemand): ~2GB
- Available for DB: ~5GB
- **Recommended Setting:** `innodb_buffer_pool_size = 4G`

### Scenario C: Dedicated Database Server (32GB RAM)
- **Recommended Setting:** `innodb_buffer_pool_size = 20G` or `24G`

---

## 3. How to Apply the Optimization

You must edit the MariaDB configuration file via SSH as the `root` user.

### Step 1: Open the configuration file
HestiaCP (on Debian/Ubuntu) stores the main MariaDB config here:
```bash
nano /etc/mysql/mariadb.conf.d/50-server.cnf
```

### Step 2: Find and change the variable
Scroll down until you find the `[mysqld]` section. Look for `innodb_buffer_pool_size`. 
If it has a `#` in front of it, remove the `#` to uncomment it, and change the value. If it doesn't exist, add it under `[mysqld]`.

Example for a server with 8GB of RAM:
```ini
[mysqld]
...
innodb_buffer_pool_size = 4G
innodb_buffer_pool_instances = 4  # Rule: 1 instance per 1GB of buffer pool
...
```

*Note: `innodb_buffer_pool_instances` divides the pool into smaller chunks to prevent CPU bottlenecking. Set it to the number of GBs of your pool (e.g., if pool is 4G, instances is 4). If pool is under 1G, leave instances at 1.*

### Step 3: Restart MariaDB
Apply the changes by restarting the database service:
```bash
systemctl restart mariadb
```

---

## 4. How to verify it worked

You can log into the MySQL console to check if the new size is active:
```bash
mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
```
*(The output will be in bytes. 4G = ~4294967296 bytes).*

## ⚠️ Warning
Never set the buffer pool larger than your physical RAM minus 2GB. If MariaDB tries to allocate more RAM than the server has, the Linux OOM (Out of Memory) Killer will instantly crash the database service, taking all your websites offline.