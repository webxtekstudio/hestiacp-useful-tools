# 🛠️ Nginx `.txt` Cache Hardener (`nginx-txt-nocache`)

*Prevents Nginx from serving `.txt` files (`robots.txt`, `llms.txt`, `ads.txt`, `security.txt`) with `expires max` static caching, and ensures dynamic CMS routes can handle missing `.txt` requests cleanly across domain rebuilds.*

---

## 🚀 1. How to Install

```bash
cd /root/hestiacp-useful-tools/scripts/nginx-txt-nocache
bash install.sh
```

To re-apply manually at any time:

```bash
v-patch-nginx-txt-nocache
```

---

## 📂 2. What It Patches

1. **Nginx Web & PHP-FPM Templates:**
   - `/usr/local/hestia/data/templates/web/nginx/*.tpl` and `*.stpl`
   - `/usr/local/hestia/data/templates/web/nginx/php-fpm/*.tpl` and `*.stpl`
   - Removes `|txt|` from static `location ~* ^.+\.(...)$` blocks.
2. **Active Domain Nginx Configs:**
   - `/home/*/conf/web/*/nginx*.conf`
   - Removes `|txt|` and reloads Nginx only after verifying `nginx -t`.
3. **Persistent Reverse-Proxy `PROXY_EXT` Definitions:**
   - `/usr/local/hestia/data/users/*/web.conf` (per-domain `PROXY_EXT` so `v-rebuild-web-domain` or Let's Encrypt renewals never re-inject `|txt|`)
   - `/usr/local/hestia/bin/v-add-web-domain`, `/usr/local/hestia/bin/v-add-web-domain-proxy`, `/usr/local/hestia/bin/v-change-web-domain-proxy-tpl`, and `/usr/local/hestia/web/templates/pages/edit_web.php` (so newly created or edited proxy domains also exclude `txt` from `PROXY_EXT`).
