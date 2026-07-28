# PHP Module Manager (CloudLinux)

An interactive, menu-driven Bash tool for managing PHP extensions, PHP versions, and CageFS on **CloudLinux** servers running **cPanel** or **DirectAdmin**.

Built for sysadmins who are tired of typing the same `dnf search` → `dnf install` → `cagefsctl --rebuild-alt-php-ini` → `selectorctl --enable-user-extensions=...` dance every time a client needs a PHP module.

---

## ✨ Features

- 📦 **Install PHP modules** — searches the correct repo (`ea-phpXX-php-*` for cPanel, `alt-phpXX-*` for DirectAdmin), auto-resolves tricky package names (`mysqli` → `mysql-meta`, `dom` → `xml`, etc.), and skips reinstalling if already present.
- 🔄 **Update / reinstall detection** — if a module is already installed, checks for available updates and offers to reinstall a possibly broken package.
- 👤 **Per-user or all-users control** — enable/disable modules and change PHP versions for a single account or the entire server.
- 🧠 **Smart `selectorctl` handling** — automatically retries with the correct `nd_*` / classic extension set when CloudLinux reports a conflict, and detects real failures instead of blindly reporting success.
- 🔍 **User info lookup** — instantly see a user's current PHP version and enabled extensions.
- 🩺 **System diagnostics** — CageFS sanity check, CageFS status, LVE limits, real-time top resource consumers, selector summary, and a one-click full CageFS refresh.
- 🔐 **ionCube & SourceGuardian installer** — installs the official CloudLinux-packaged loaders (with automatic fallback to the testing repo) and enables them via `selectorctl`.
- 🛡️ **Environment-aware** — detects when a PHP version is **native** (not alt-php/ea-php managed) or when **CageFS is disabled**, and gracefully skips steps that would silently fail.
- 🎨 **Clean, colorized terminal UI** — step-by-step sections, aligned tables, and clear ✔ / ⚠ / ✘ status indicators.
- 🔒 **Secure by design** — uses `mktemp` for all temporary log files (no predictable `/tmp` paths, no symlink-attack surface).

---

## 📋 Requirements

- A CloudLinux server (cPanel or DirectAdmin)
- Root access
- `dnf` or `yum`
- CloudLinux tools in `PATH`: `cagefsctl`, `selectorctl` (and optionally `lvectl`, `lveinfo`, `lvetop`/`lveps` for diagnostics)

> The script degrades gracefully if some tools are missing or if CageFS is disabled — it will tell you exactly what it skipped and why.

---

## 🚀 Usage

```bash
chmod +x php-manager.sh
./php-manager.sh
```

You'll land on the main menu:

```
########################################
#      PHP MODULE MANAGER (CloudLinux)  #
########################################

  1) Install Module
  2) User Info
  3) Manage User PHP Settings
  4) System Diagnostics & Maintenance
  5) ionCube & SourceGuardian
  6) Manual Extension Enable (beta)
  7) Exit
```

### 1) Install Module
Pick a module from the numbered list, **or just type any module name manually** (handy for modules not in the list, or when the real package name differs — e.g. typing `dom` automatically searches for `xml`).

### 3) Manage User PHP Settings
```
1) Change PHP version for a specific user
2) Change PHP version for all users ⚠️
3) Enable a module for a specific user
4) Enable a module for all users ⚠️
5) Disable a module for a specific user
6) Disable a module for all users ⚠️
0) Back to main menu
```

### 4) System Diagnostics & Maintenance
```
1) CageFS Sanity Check
2) CageFS Status
3) List LVE Limits (all users)
4) LVE Usage Info (last 1 day, all users)
5) LVE Usage Info for a Specific User
6) Clean Old CageFS Data ⚠️
7) Selector Summary
8) Full CageFS Refresh (force-update + remount-all + rebuild ini + update etc)
9) Top 5 Resource Consumers (real-time)
0) Back to main menu
```

### 5) ionCube & SourceGuardian
```
1) ionCube Loader only
2) SourceGuardian only
3) Both
```
Installs the official CloudLinux packages for the chosen PHP version, falling back to the `cloudlinux-updates-testing` repo if the stable repo doesn't have it yet, then enables the loader(s) via `selectorctl`.

### 6) Manual Extension Enable (beta)
For the case `Install Module` can't solve: the package is already installed and the `.so` file exists on disk, but no `.ini` file was ever created to load it (this happens with some older/edge-case CloudLinux packages). This mode:
- Detects **every** PHP installation for the given version on the box (`alt-php`, `ea-php`, and native `/usr/local/phpXX` builds can all coexist) and lets you pick the right one instead of guessing from the panel type
- Locates the `.so` file automatically, picks `extension=` or `zend_extension=` correctly (loaders like ionCube/SourceGuardian need the latter)
- Backs up any existing `.ini` before overwriting
- Verifies the extension actually loads with `php -m` — if it doesn't, it **automatically reverts** the change instead of leaving a broken config
- Runs the usual CageFS refresh + `selectorctl` enable afterward (skipped entirely for native PHP, which isn't CloudLinux-managed)

---

## 🧩 Module Name Aliases

Some PHP extension names don't match their actual package name. The script resolves these automatically:

| You type      | Package searched |
|----------------|------------------|
| `mysqli`, `pdo_mysql`, `mysql` | `mysql-meta` |
| `json` | `jsonc` |
| `dom`, `libxml`, `simplexml`, `xmlreader`, `xmlwriter`, `xsl` | `xml` |
| `pdo_pgsql` | `pgsql` |
| `pdo_sqlite` | `sqlite3` |
| `pdo_odbc` | `odbc` |
| `pdo_dblib` | `sybase` |
| `pdo_firebird` | `interbase` |
| `ioncube_loader` | `ioncube-loader` |

If a module isn't in this table and the direct search finds nothing, the script prompts you to type the exact package name manually.

---

## 🏭 Built for Multi-User Scale (300–400+ accounts)

- **Batch module install** — select multiple modules in one session; the script installs each package individually but runs the heavy CageFS refresh (`rebuild-alt-php-ini`, `force-update-etc`, `force-update`) **only once** at the end, instead of once per module. Consider running larger batches during low-traffic hours.
- **screen/tmux advisory** — if you're not inside `screen` or `tmux`, the script warns that a dropped SSH session could leave a `--for-all-users` operation half-done, and asks you to confirm before continuing.
- **Persistent audit log** — every install, enable/disable, PHP version change, and CageFS maintenance action is appended (with timestamp and the sudo user) to `/var/log/php-manager.log` — independent of the temporary per-command `$LOGFILE`, which is only for debugging a single command's raw output.
- **Username validation** — usernames are checked with `id` before being passed to `selectorctl`, so a typo is caught immediately instead of surfacing as a confusing `selectorctl` error.

---

## 🛟 Safety Checks Built In

- **Native PHP detection** — before touching `cagefsctl`/`selectorctl`, the script verifies `/opt/alt/phpXX` (or `/opt/cpanel/ea-phpXX`) actually exists. If it doesn't, it stops and tells you this PHP version is native/manually-built and explains why CloudLinux tooling won't help.
- **CageFS status check** — if CageFS is disabled, package installation still proceeds, but the CageFS/selector steps are skipped with a clear explanation instead of failing silently.
- **`selectorctl` conflict handling** — retries between the `nd_*` and classic extension sets (e.g. `nd_mysqli` ↔ `mysqli`) when CloudLinux reports `"skipped as conflicting"`, and distinguishes a **partial** conflict (some accounts already on the other family — reported with the specific account names) from a **total** conflict (falls through to the next candidate set).
- **Real failure detection** — checks actual exit codes and scans output for `error`/`exception`/`traceback`, instead of assuming success just because the command didn't crash.

---

## 🔒 Security Notes

All temporary command output is written to a file created with `mktemp`:

```bash
LOGFILE=$(mktemp /tmp/php_module_cmd.XXXXXX.log)
```

This avoids the symlink-attack risk of writing to a fixed, predictable path in `/tmp` that other local users could pre-create or intercept.

---

## ⚠️ Disclaimer

This is a convenience wrapper around standard CloudLinux/cPanel/DirectAdmin tools. It does not replace understanding what `cagefsctl` and `selectorctl` do — always review destructive actions (marked with ⚠️) before confirming, especially anything applied to **all users**.
