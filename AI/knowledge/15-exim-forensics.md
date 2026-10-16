# Email Forensics (Exim4 & Dovecot) in HestiaCP

To answer questions such as "how many emails were received", "what were the subjects", and "who sent them", AI agents MUST follow these rules, as default Linux mail paths do not apply to HestiaCP.

## 1. Where Are Emails Physically Stored?
HestiaCP does **NOT** use `/var/vmail/`. All delivered emails are organized by HestiaCP user, domain, and mail account under:
`/home/<Hestia_User>/mail/<Domain>/<Account>/`

Primary Maildir directories inside each account:
- `new/` (Newly arrived, unread emails)
- `cur/` (Emails already processed/read by an IMAP client)

**Example:** If the HestiaCP user is `admin`, the domain is `example.com`, and the email account is `info`, the path is:
`/home/admin/mail/example.com/info/`

## 2. Reading "Subject" and "From" Headers
By default in HestiaCP, `/var/log/exim4/mainlog` does **NOT** log email `Subject` headers. Never search for `Subject` inside `mainlog`.
Also do not use `exim -Mvh` for delivered emails because Exim removes messages from the spool queue (`/var/spool/exim4/`) as soon as they are delivered.

**The ONLY reliable way** to inspect sender and subject lines of recent delivered emails is to search both `new` and `cur` directories using `find` + `grep` (since mobile/desktop IMAP clients move messages from `new` to `cur` immediately):

```bash
# Always search both 'new' and 'cur' for messages from the last 24 hours (-mmin -1440):
sudo find /home/*/mail/example.com/info/new /home/*/mail/example.com/info/cur -type f -mmin -1440 -exec grep -H -i "^Subject:" {} + 2>/dev/null
sudo find /home/*/mail/example.com/info/new /home/*/mail/example.com/info/cur -type f -mmin -1440 -exec grep -H -i "^From:" {} + 2>/dev/null
```

## 3. Counting Delivered Incoming Emails Today
To count ONLY emails that were actually delivered to a local mailbox on a specific date (excluding rejected spam, bounces, or queue retries):
1. Query `/var/log/exim4/mainlog`
2. Filter by date prefix (e.g., `2026-04-09`)
3. Filter by local mailbox delivery token `=> <account>@<domain>`

**Example:**
```bash
sudo grep "^2026-04-09" /var/log/exim4/mainlog | grep "=> info <info@example.com>" | wc -l
```

## 4. What NEVER to Do
- **NEVER** look inside `/var/vmail/`.
- **NEVER** guess or fabricate email subjects from `/var/log/exim4/mainlog`. Always run `grep` against the physical Maildir under `/home/`.
- **NEVER** guess Exim spool IDs that `exim -Mvh` cannot find.

