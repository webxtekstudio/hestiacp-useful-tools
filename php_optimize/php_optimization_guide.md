# Comprehensive PHP-FPM Optimization Guide for HestiaCP

This guide provides a deep dive into PHP-FPM process management, explaining the different modes, how to calculate the optimal settings based on your server's hardware, and practical examples for various scenarios. Proper PHP-FPM tuning is critical for balancing website speed and server stability.

---

## 1. The Three PHP-FPM Modes

When a server runs PHP websites (like WordPress), it uses PHP-FPM (FastCGI Process Manager). FPM controls how the server handles PHP "workers" or "processes". Think of processes as employees waiting to serve customers (visitors).

### A. Static Mode
- **How it works:** The server creates a fixed number of processes when it starts and keeps them running forever, regardless of traffic.
- **Pros:** Maximum performance and lowest latency. There is zero delay because workers are always ready.
- **Cons:** High and constant memory consumption. It reserves RAM even if no one is visiting the website.
- **When to use:** Extremely high-traffic websites (e.g., an active e-commerce store with thousands of daily visitors) hosted on a dedicated server or a VPS with abundant RAM where the site is the *only* priority.

### B. Dynamic Mode
- **How it works:** The server keeps a minimum number of processes running at all times (e.g., 2). If traffic spikes, it creates more processes up to a defined maximum, and then kills the extra ones when traffic drops.
- **Pros:** Good balance between performance and memory. Faster than ondemand for the first visitor because some workers are always alive.
- **Cons:** Still wastes RAM during periods of zero traffic because the "minimum" processes never die.
- **When to use:** Medium to high-traffic websites with constant, predictable visitor flow (e.g., a news blog that always has at least 5-10 people reading at any given time).

### C. Ondemand Mode
- **How it works:** The server starts with zero processes. When a visitor arrives, it instantly creates a process to serve them. If there are no new visitors for a certain time (e.g., 10 seconds), the process is killed to free up RAM.
- **Pros:** Excellent memory efficiency. You can host dozens of websites on a small server without running out of RAM.
- **Cons:** Slight delay (milliseconds) for the very first visitor after a period of inactivity while the server spins up a new worker.
- **When to use:** Shared hosting environments, agency servers hosting multiple small/medium client websites, portfolios, or landing pages with sporadic traffic.

---

## 2. The Golden Rule of PHP Optimization: Memory vs. Processes

To configure PHP correctly, you must understand this formula:
**Total RAM needed = (Max PHP Workers) × (Average RAM per Worker)**

*   A standard WordPress worker consumes about **40MB to 80MB** of RAM.
*   A heavy WooCommerce worker might consume **100MB to 150MB** of RAM.

If you set `pm.max_children = 50` on a site, that single site could theoretically demand `50 * 80MB = 4000MB (4GB)` of RAM during a traffic spike. If your server only has 2GB of RAM, it will crash.

### Key Configuration Variables:
*   `pm.max_children`: The absolute maximum number of workers allowed to run simultaneously. **This is the most critical setting to prevent server crashes.**
*   `pm.start_servers` *(Dynamic only)*: Number of workers created on startup.
*   `pm.min_spare_servers` *(Dynamic only)*: Minimum idle workers kept alive.
*   `pm.max_spare_servers` *(Dynamic only)*: Maximum idle workers kept alive.
*   `pm.process_idle_timeout` *(Ondemand only)*: How long to wait before killing an idle worker (usually 10s).
*   `pm.max_requests`: How many requests a worker handles before it is restarted (prevents memory leaks). Setting this to `500` is generally safe.

---

## 3. Practical Examples & Formulas

Here are real-world scenarios to help you configure your server.

### Scenario A: The "Agency" Server (Many Small Sites)
*   **Hardware:** 4 Cores, 8GB RAM.
*   **Workload:** 30 small client websites (WordPress portfolios, low traffic).
*   **The Problem:** If you use `dynamic` mode, 30 sites * 2 minimum workers * 50MB = 3GB of RAM wasted 24/7 just doing nothing.
*   **The Solution: ONDEMAND**
    *   Set all sites to `ondemand`.
    *   Set `pm.max_children = 4` or `5` per site. (If all 5 workers are busy, it uses ~250MB per site, which is safe).
    *   Result: The server will sit at ~1GB RAM usage when idle and easily handle traffic spikes across different sites.

### Scenario B: The "Flagship" E-commerce Site
*   **Hardware:** 4 Cores, 8GB RAM.
*   **Workload:** 1 single, heavy WooCommerce site with 5,000 visitors per day.
*   **The Problem:** Using `ondemand` will cause micro-delays for users, hurting sales.
*   **The Solution: DYNAMIC or STATIC**
    *   We have 8GB RAM. Let's reserve 2GB for the OS and Database, leaving 6GB (6000MB) for PHP.
    *   WooCommerce workers use ~100MB.
    *   Math: `6000MB / 100MB = 60 workers maximum`.
    *   **Configuration (Dynamic):**
        *   `pm.max_children = 60`
        *   `pm.start_servers = 10`
        *   `pm.min_spare_servers = 10`
        *   `pm.max_spare_servers = 20`
    *   **Configuration (Static):**
        *   `pm.max_children = 40` (A bit more conservative for stability).

### Scenario C: The "Budget" VPS
*   **Hardware:** 1 Core, 1GB RAM or 2GB RAM.
*   **Workload:** 3 to 5 medium websites.
*   **The Problem:** Very limited RAM. `max_children` must be strictly controlled to prevent Out of Memory (OOM) errors.
*   **The Solution: ONDEMAND (Strict)**
    *   Math for 1GB RAM: OS takes ~400MB. DB takes ~200MB. Leaves ~400MB for PHP.
    *   `400MB / 50MB per worker = 8 workers TOTAL across the whole server`.
    *   If you have 4 sites, configure each with:
        *   Mode: `ondemand`
        *   `pm.max_children = 2` (or max 3).

---

## 4. How to Apply These Changes in HestiaCP

HestiaCP manages these settings via templates.

### Changing the Mode (Ondemand vs Dynamic)
1. In the HestiaCP panel, edit the Web Domain.
2. Go to **Advanced Options**.
3. Change the **Backend Template**:
    *   `default`: Usually set to **ondemand** in modern HestiaCP setups.
    *   `PHP-x_x`: Usually set to **ondemand**.
    *   If you need a custom setup (like Scenario B), you should create a custom template.

### Creating a Custom Template for High Traffic (Static/Dynamic)
To apply custom `max_children` or `static` mode, you need to duplicate an existing template:

1. Connect via SSH as root.
2. Go to the template folder:
   ```bash
   cd /usr/local/hestia/data/templates/web/php-fpm/
   ```
3. Copy the default template to a new name:
   ```bash
   cp default.tpl high-traffic.tpl
   ```
4. Edit the new template (`nano high-traffic.tpl`) and modify the variables according to your math:
   ```ini
   pm = dynamic
   pm.max_children = 40
   pm.start_servers = 5
   pm.min_spare_servers = 5
   pm.max_spare_servers = 10
   pm.max_requests = 500
   ```
5. Go back to the HestiaCP web panel, edit the domain, and select your new `high-traffic` backend template.

## Conclusion
- Default to **Ondemand** for almost everything, especially if you host multiple domains.
- Calculate your **RAM limits** before blindly increasing `max_children`.
- Reserve **Dynamic or Static** only for sites that genuinely generate revenue or have constant, heavy traffic where every millisecond counts.