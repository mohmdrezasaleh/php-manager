#!/bin/bash

LOGFILE=$(mktemp /tmp/php-manager.XXXXXX.log) || { echo "Failed to create secure temp log file." >&2; exit 1; }

cleanup_logfile() {
    if [[ -s "$LOGFILE" ]]; then
        echo -e "\033[2m[i] Last command log kept for review: $LOGFILE\033[0m" >&2
    else
        rm -f "$LOGFILE"
    fi
}
trap cleanup_logfile EXIT
AUDIT_LOG="/var/log/php-manager.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
STEP_COLOR='\033[38;2;100;200;180m'
CPANEL_COLOR='\033[38;2;255;108;44m'
DA_COLOR='\033[38;2;10;109;170m'
NC='\033[0m'

SEP_LEN=54

separator() {
    printf "${DIM}"
    printf '%.0s-' $(seq 1 "$SEP_LEN")
    printf "${NC}\n"
}

step_header() {
    local title="$1"
    echo ""
    separator
    echo -e "${BOLD}${STEP_COLOR}${title}${NC}"
    separator
}

log()  { echo -e "  ${GREEN}✔${NC} $1"; }
info() { echo -e "  ${BLUE}➜${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✘${NC} $1"; }

if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root (EUID=$EUID)."
    echo -e "  ${DIM}Try: sudo bash $0${NC}"
    exit 1
fi

run_cmd() {
    local label="$1"; shift
    echo -en "  ${MAGENTA}▶ Running:${NC} ${label} ... "
    if "$@" &>"$LOGFILE"; then
        echo -e "${GREEN}done${NC}"
        return 0
    else
        echo -e "${RED}failed${NC}"
        warn "See $LOGFILE for details."
        return 1
    fi
}

confirm_all_users() {
    local action="$1"

    if [[ -z "${STY:-}" && -z "${TMUX:-}" ]]; then
        warn "You are not running inside screen or tmux."
        warn "If your SSH session drops during this 'for all users' operation, it may be left half-done."
        read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Continue anyway?${NC} ${DIM}(y/n)${NC}: ")" _tmux_confirm
        if [[ "$_tmux_confirm" != "y" && "$_tmux_confirm" != "Y" ]]; then
            info "Cancelled. Start a screen/tmux session first, e.g.: screen -S php-manager"
            return 1
        fi
    fi

    read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ This will ${action} for ALL USERS on this server. Continue? ⚠️${NC} ${DIM}(y/n)${NC}: ")" _confirm
    [[ "$_confirm" == "y" || "$_confirm" == "Y" ]]
}

audit_log() {
    local action="$1"
    local who="${SUDO_USER:-root}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$who] $action" >> "$AUDIT_LOG" 2>/dev/null || warn "Could not write to audit log: $AUDIT_LOG"
}

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "########################################"
    echo "#      PHP MODULE MANAGER (CloudLinux)  #"
    echo "########################################"
    echo -e "${NC}"
}

MODULES=(
    bcmath bz2 calendar curl dom exif fileinfo gd gmp iconv imagick
    imap intl ioncube_loader json ldap mbstring mysqli mysqlnd opcache
    openssl pdo pdo_mysql redis soap sockets sodium zip
)

declare -A MODULE_ALIASES=(
    [mysqli]="mysql-meta"
    [pdo_mysql]="mysql-meta"
    [mysql]="mysql-meta"
    [json]="jsonc"
    [ioncube_loader]="ioncube-loader"
    [dom]="xml"
    [libxml]="xml"
    [simplexml]="xml"
    [xmlreader]="xml"
    [xmlwriter]="xml"
    [xsl]="xml"
    [pdo_pgsql]="pgsql"
    [pdo_sqlite]="sqlite3"
    [pdo_odbc]="odbc"
    [pdo_dblib]="sybase"
    [pdo_firebird]="interbase"
)

declare -A SELECTOR_EXTENSION_CANDIDATES=(
    [mysqli]="nd_mysqli mysqli"
    [pdo_mysql]="nd_pdo_mysql pdo_mysql"
    [mysql]="nd_mysql mysql"
)

resolve_module_alias() {
    local mod="$1"
    if [[ -n "${MODULE_ALIASES[$mod]:-}" ]]; then
        echo "${MODULE_ALIASES[$mod]}"
    else
        echo ""
    fi
}

resolve_selector_candidates() {
    local mod="$1"
    if [[ -n "${SELECTOR_EXTENSION_CANDIDATES[$mod]:-}" ]]; then
        echo "${SELECTOR_EXTENSION_CANDIDATES[$mod]}"
    else
        echo "$mod"
    fi
}

validate_phpver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]]
}

detect_panel_and_os() {
    PANEL=""
    if [[ -d /usr/local/cpanel ]]; then
        PANEL="cpanel"
        echo -e "  ${CPANEL_COLOR}${BOLD}● Panel: cPanel${NC}"
    elif [[ -d /usr/local/directadmin ]]; then
        PANEL="directadmin"
        echo -e "  ${DA_COLOR}${BOLD}● Panel: DirectAdmin${NC}"
    else
        err "Panel not detected (neither cPanel nor DirectAdmin found)."
        return 1
    fi

    check_is_cloudlinux
    if $IS_CLOUDLINUX; then
        log "OS: CloudLinux"
    else
        warn "CloudLinux not detected — some steps may be skipped."
    fi

    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
}

check_cagefs_status() {
    CAGEFS_ENABLED=false
    if command -v cagefsctl &>/dev/null; then
        CAGEFS_STATUS_OUTPUT=$(cagefsctl --cagefs-status 2>&1)
        if echo "$CAGEFS_STATUS_OUTPUT" | grep -qi "enabled"; then
            CAGEFS_ENABLED=true
            log "CageFS status: ${GREEN}Enabled${NC}"
        else
            warn "CageFS appears to be Disabled on this system."
            warn "cagefsctl/selectorctl steps will be skipped since they depend on CageFS."
        fi
    else
        warn "cagefsctl not found — cannot verify CageFS status."
    fi
}

check_is_cloudlinux() {
    IS_CLOUDLINUX=false
    if [[ -f /etc/cloudlinux-release ]] || grep -qi cloudlinux /etc/os-release 2>/dev/null; then
        IS_CLOUDLINUX=true
    fi
}

refresh_cagefs() {
    if ! command -v cagefsctl &>/dev/null; then
        warn "cagefsctl not found, skipping CageFS steps."
        return 1
    fi
    run_cmd "rebuild php ini" cagefsctl --rebuild-alt-php-ini
    run_cmd "update etc"      cagefsctl --force-update-etc
    run_cmd "force update"    cagefsctl --force-update
}

detect_php_installations() {
    local phpver="$1"
    PHP_INSTALL_CANDIDATES=()
    [[ -d "/opt/alt/php${phpver}" ]] && PHP_INSTALL_CANDIDATES+=("alt:/opt/alt/php${phpver}")
    [[ -d "/opt/cpanel/ea-php${phpver}/root" ]] && PHP_INSTALL_CANDIDATES+=("ea:/opt/cpanel/ea-php${phpver}/root")
    [[ -d "/usr/local/php${phpver}" ]] && PHP_INSTALL_CANDIDATES+=("native:/usr/local/php${phpver}")
}

select_php_targets() {
    local phpver="$1"
    local allow_native="$2"

    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi

    detect_php_installations "$phpver"

    if [[ "$allow_native" != "yes" ]]; then
        local filtered=() c
        for c in "${PHP_INSTALL_CANDIDATES[@]}"; do
            [[ "$c" == native:* ]] || filtered+=("$c")
        done
        PHP_INSTALL_CANDIDATES=("${filtered[@]}")
    fi

    if [[ ${#PHP_INSTALL_CANDIDATES[@]} -eq 0 ]]; then
        err "No package-manageable PHP ${phpver} installation found (checked alt-php and ea-php under /opt)."
        SELECTED_PHP_TARGETS=()
        return 1
    fi

    if [[ ${#PHP_INSTALL_CANDIDATES[@]} -eq 1 ]]; then
        SELECTED_PHP_TARGETS=("${PHP_INSTALL_CANDIDATES[0]}")
        local k r
        IFS=':' read -r k r <<< "${PHP_INSTALL_CANDIDATES[0]}"
        log "Found one PHP ${phpver} installation: ${BOLD}$r${NC} ${DIM}(${k})${NC}"
        return 0
    fi

    warn "Multiple PHP ${phpver} installations found on this server — panel type alone doesn't tell us which one your sites actually use:"
    local i=1 c k r
    for c in "${PHP_INSTALL_CANDIDATES[@]}"; do
        IFS=':' read -r k r <<< "$c"
        echo -e "  ${CYAN}${i})${NC} $r ${DIM}(${k})${NC}"
        i=$((i+1))
    done
    echo -e "  ${CYAN}a)${NC} All of the above"

    local pick=""
    while true; do
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Select installation number, or 'a' for all${NC}: ")" pick
        if [[ "$pick" == "a" || "$pick" == "A" ]]; then
            SELECTED_PHP_TARGETS=("${PHP_INSTALL_CANDIDATES[@]}")
            return 0
        fi
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#PHP_INSTALL_CANDIDATES[@]} )); then
            SELECTED_PHP_TARGETS=("${PHP_INSTALL_CANDIDATES[$((pick-1))]}")
            return 0
        fi
        err "Invalid selection."
    done
}

check_php_environment() {
    local phpver="$1"
    local dir_type="$2"
    local phpver_display="${3:-$phpver}"

    if [[ "$dir_type" == "ea" ]]; then
        MANAGED_PHP_DIR="/opt/cpanel/ea-php${phpver}"
    else
        MANAGED_PHP_DIR="/opt/alt/php${phpver}"
    fi

    IS_MANAGED_PHP=false
    if [[ -d "$MANAGED_PHP_DIR" ]]; then
        IS_MANAGED_PHP=true
        log "PHP ${phpver_display} confirmed as panel-managed: ${DIM}${MANAGED_PHP_DIR}${NC}"
    else
        err "PHP ${phpver_display} does not appear to be panel-managed (no ${MANAGED_PHP_DIR})."
        warn "This is likely a NATIVE / manually-built PHP, not managed by CloudLinux."
        warn "selectorctl, cagefsctl, and alt-phpXX-*/ea-phpXX-* packages do not apply here."
        info "For native PHP, install extensions manually (distro packages or compiled .so + php.ini/php.conf.d entry)."
    fi

    check_cagefs_status
}

read_php_version() {
    local prompt_text="$1"
    local __resultvar="$2"
    local ver=""
    while [[ -z "$ver" ]] || ! validate_phpver "$ver"; do
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ ${prompt_text}${NC} ${DIM}(e.g. 8.2)${NC}: ")" ver
        if ! validate_phpver "$ver"; then
            err "Invalid version format. Expected format: 8.2"
            ver=""
        fi
    done
    printf -v "$__resultvar" '%s' "$ver"
}

read_username() {
    local __resultvar="$1"
    local uname=""
    while true; do
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Enter username${NC}: ")" uname
        if [[ -z "$uname" ]]; then
            err "Username cannot be empty."
            continue
        fi
        if id "$uname" &>/dev/null; then
            printf -v "$__resultvar" '%s' "$uname"
            return 0
        else
            err "User '$uname' does not exist on this system. Check for typos."
        fi
    done
}

show_modules_menu() {
    echo ""
    local i=1
    local col=0
    for m in "${MODULES[@]}"; do
        printf "  ${CYAN}%2d)${NC} %-18s" "$i" "$m"
        col=$((col+1))
        if (( col % 3 == 0 )); then echo ""; fi
        i=$((i+1))
    done
    echo ""
    info "Not listed? Just type the module name directly ${DIM}(e.g. dom's real package is often 'xml')${NC}."
}

select_module_from_list() {
    local __resultvar="$1"
    local choice=""
    local mod=""
    show_modules_menu
    while true; do
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Select a module number or type a module name${NC}: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && choice <= ${#MODULES[@]} )); then
                mod="${MODULES[$((choice-1))]}"
                break
            else
                err "Invalid number. Enter a number between 1 and ${#MODULES[@]}."
            fi
        elif [[ "$choice" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            mod="$choice"
            break
        else
            err "Invalid input. Enter a number (1-${#MODULES[@]}) or a valid module name (letters, numbers, underscore only)."
        fi
    done
    printf -v "$__resultvar" '%s' "$mod"
}

enable_selector_extension() {
    local mod="$1" ver="$2" scope="$3" username="$4"
    local candidates
    read -ra candidates <<< "$(resolve_selector_candidates "$mod")"

    local ext
    for ext in "${candidates[@]}"; do
        echo -en "  ${MAGENTA}▶ Running:${NC} enabling extension {${CYAN}${BOLD}${ext}${NC}} "

        local SEL_EXIT=0
        if [[ "$scope" == "all" ]]; then
            echo -en "${DIM}(all users, may take a while)${NC} ... "
            selectorctl --enable-user-extensions="$ext" --version="$ver" --for-all-users &>"$LOGFILE" || SEL_EXIT=$?
        else
            echo -en "${DIM}(user: $username)${NC} ... "
            selectorctl --enable-user-extensions="$ext" --version="$ver" --user="$username" &>"$LOGFILE" || SEL_EXIT=$?
        fi

        local total_lines conflict_lines
        total_lines=$(grep -c . "$LOGFILE" 2>/dev/null)
        total_lines=${total_lines:-0}
        conflict_lines=$(grep -ic "skipped as conflicting" "$LOGFILE" 2>/dev/null)
        conflict_lines=${conflict_lines:-0}

        if [[ "$conflict_lines" -gt 0 && "$total_lines" -gt "$conflict_lines" ]]; then
            echo -e "${YELLOW}done, but ${conflict_lines} account(s) conflicted${NC}"
            warn "Some accounts already had a different (incompatible) extension set active and were skipped for '${ext}':"
            grep -i "skipped as conflicting" "$LOGFILE" | sed 's/^/    /'
            info "Those accounts likely need manual review — try the other candidate set for them individually."
            return 0
        fi

        if [[ "$conflict_lines" -gt 0 ]]; then
            echo -e "${YELLOW}conflicting for every account${NC}"
            continue
        fi

        if [[ $SEL_EXIT -ne 0 ]] || grep -qiE "error|traceback|exception" "$LOGFILE"; then
            echo -e "${RED}failed${NC}"
            echo -e "${DIM}"
            sed 's/^/    /' "$LOGFILE"
            echo -e "${NC}"
            return 1
        fi

        echo -e "${GREEN}done${NC}"
        return 0
    done

    err "Could not enable '$mod' — every candidate extension set conflicted for all accounts."
    info "This usually means some accounts still have leftover state from an earlier manual enable/disable."
    echo -e "${DIM}"
    sed 's/^/    /' "$LOGFILE"
    echo -e "${NC}"
    return 1
}

disable_selector_extension() {
    local mod="$1" ver="$2" scope="$3" username="$4"
    local candidates
    read -ra candidates <<< "$(resolve_selector_candidates "$mod")"
    local joined
    joined=$(IFS=,; echo "${candidates[*]}")

    echo -en "  ${MAGENTA}▶ Running:${NC} disabling extension {${CYAN}${BOLD}${joined}${NC}} "

    local scope_desc
    if [[ "$scope" == "all" ]]; then
        echo -en "${DIM}(all users)${NC} ... "
        scope_desc="--for-all-users"
    else
        echo -en "${DIM}(user: $username)${NC} ... "
        scope_desc="--user=$username"
    fi

    if selectorctl --disable-user-extensions="$joined" --version="$ver" $scope_desc &>"$LOGFILE"; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
        warn "See $LOGFILE for details."
    fi
}

install_package_with_testing_fallback() {
    local pkg="$1"
    local allow_testing_repo="$2"

    if run_cmd "$PKG_MGR install -y $pkg" "$PKG_MGR" install -y "$pkg"; then
        return 0
    fi

    if [[ "$allow_testing_repo" == "yes" ]]; then
        warn "Not found in stable repo. Retrying via cloudlinux-updates-testing ..."
        run_cmd "$PKG_MGR install -y $pkg --enablerepo=cloudlinux-updates-testing" \
            "$PKG_MGR" install -y "$pkg" --enablerepo=cloudlinux-updates-testing && return 0
    fi

    return 1
}

install_one_module_package() {
    local module="$1"
    local original_module="$module"

    step_header "Package: ${module}"

    local alias_pkg
    alias_pkg=$(resolve_module_alias "$module")
    local check_candidates=("${PKG_PREFIX}${module}")
    [[ -n "$alias_pkg" ]] && check_candidates+=("${PKG_PREFIX}${alias_pkg}")

    local found_pkg=""
    local candidate
    for candidate in "${check_candidates[@]}"; do
        if rpm -q "$candidate" &>/dev/null; then
            found_pkg="$candidate"
            [[ "$candidate" == "${PKG_PREFIX}${alias_pkg}" ]] && module="$alias_pkg"
            break
        fi
    done

    local already_installed=false
    if [[ -n "$found_pkg" ]]; then
        log "Package already installed: ${BOLD}$found_pkg${NC}"
        already_installed=true

        info "Checking for available updates..."
        local update_check update_line
        update_check=$($PKG_MGR check-update "$found_pkg" 2>/dev/null || true)
        update_line=$(echo "$update_check" | grep -E "^${found_pkg}\." || true)

        if [[ -n "$update_line" ]]; then
            warn "A newer version is available:"
            echo -e "${DIM}"
            echo "$update_line" | sed 's/^/  /'
            echo -e "${NC}"
            echo -e "  ${CYAN}1)${NC} Update to latest version"
            echo -e "  ${CYAN}2)${NC} Reinstall current version"
            echo -e "  ${CYAN}3)${NC} Skip"
            read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Choose an option${NC}: ")" pkg_action
            case "$pkg_action" in
                1) run_cmd "$PKG_MGR update -y $found_pkg" "$PKG_MGR" update -y "$found_pkg" ;;
                2) run_cmd "$PKG_MGR reinstall -y $found_pkg" "$PKG_MGR" reinstall -y "$found_pkg" ;;
                *) info "Keeping current version." ;;
            esac
        else
            log "Already up to date."
            echo -e "  ${CYAN}1)${NC} Keep as is"
            echo -e "  ${CYAN}2)${NC} Reinstall anyway (fix a possibly broken package)"
            read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Choose an option${NC}: ")" pkg_action
            if [[ "$pkg_action" == "2" ]]; then
                run_cmd "$PKG_MGR reinstall -y $found_pkg" "$PKG_MGR" reinstall -y "$found_pkg"
            fi
        fi
    else
        info "Not installed yet. Proceeding to search."
    fi

    if ! $already_installed; then
        local search_pattern
        if [[ "$PANEL" == "cpanel" ]]; then
            search_pattern="*ea-php${PHPVER}*${module}*"
        else
            search_pattern="*alt-php${PHPVER}*${module}*"
        fi

        info "Search pattern: ${BOLD}$search_pattern${NC}"

        local search_results
        search_results=$($PKG_MGR search "$search_pattern" 2>/dev/null | grep -E "^[a-zA-Z0-9._+-]+\.(x86_64|noarch)" | grep -v -- '-debuginfo' || true)

        if [[ -z "$search_results" && -n "$alias_pkg" ]]; then
            warn "No package found for '$module'. Trying known alias '${alias_pkg}' ..."
            if [[ "$PANEL" == "cpanel" ]]; then
                search_pattern="*ea-php${PHPVER}*${alias_pkg}*"
            else
                search_pattern="*alt-php${PHPVER}*${alias_pkg}*"
            fi
            info "Search pattern: ${BOLD}$search_pattern${NC}"
            search_results=$($PKG_MGR search "$search_pattern" 2>/dev/null | grep -E "^[a-zA-Z0-9._+-]+\.(x86_64|noarch)" | grep -v -- '-debuginfo' || true)
            [[ -n "$search_results" ]] && module="$alias_pkg"
        fi

        if [[ -n "$search_results" ]]; then
            echo -e "${DIM}"
            echo "$search_results" | head -n 10 | sed 's/^/  /'
            echo -e "${NC}"
        else
            warn "No matching packages found in search results."
        fi

        local exact_pkg="${PKG_PREFIX}${module}"
        found_pkg=$(echo "$search_results" | awk -v exact="$exact_pkg" '{split($1,a,"."); if (a[1]==exact) print a[1]}' | head -n1)

        if [[ -z "$found_pkg" ]]; then
            found_pkg=$(echo "$search_results" | head -n1 | awk '{print $1}' | sed 's/\.[a-zA-Z0-9_]*$//')
        fi

        if [[ -z "$found_pkg" ]]; then
            warn "No package auto-detected."
            read -rp "$(echo -e "  ${CYAN}${BOLD}➜ Enter exact package name${NC} ${DIM}(default: ${PKG_PREFIX}${module})${NC}: ")" manual_pkg
            found_pkg="${manual_pkg:-${PKG_PREFIX}${module}}"
        fi

        log "Selected package: ${BOLD}$found_pkg${NC}"

        read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Install '${found_pkg}' now?${NC} ${DIM}(y/n)${NC}: ")" confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            warn "Installation of '$module' cancelled by user."
            return 1
        fi

        local allow_testing="no"
        [[ "$original_module" == "ioncube_loader" || "$original_module" == "sourceguardian" ]] && allow_testing="yes"

        install_package_with_testing_fallback "$found_pkg" "$allow_testing" || {
            err "Package installation for '$module' failed."
            return 1
        }
    fi

    INSTALLED_MODULE_NAME="$original_module"
    return 0
}

run_post_install_tasks() {
    local -n modules_ref="$1"
    local phpver_raw="$2"

    step_header "CloudLinux Post-Install Tasks"

    if [[ ${#modules_ref[@]} -eq 0 ]]; then
        warn "No modules were successfully installed — skipping CageFS refresh and selector steps."
        return 1
    fi

    if $IS_CLOUDLINUX && $CAGEFS_ENABLED; then
        refresh_cagefs

        if command -v selectorctl &>/dev/null; then
            if confirm_all_users "enable ${modules_ref[*]}"; then
                local mod
                for mod in "${modules_ref[@]}"; do
                    enable_selector_extension "$mod" "$phpver_raw" "all"
                done
                audit_log "Installed and enabled [${modules_ref[*]}] (PHP ${phpver_raw}) for ALL USERS"
            else
                info "Skipped enabling. Packages are installed but not activated for users."
                audit_log "Installed [${modules_ref[*]}] (PHP ${phpver_raw}), enable skipped by admin"
            fi
        fi
    else
        warn "Skipped (not CloudLinux, or CageFS is disabled)."
        if $IS_CLOUDLINUX && ! $CAGEFS_ENABLED; then
            info "Packages are installed, but you'll need to enable the extensions manually since CageFS is off."
        fi
        audit_log "Installed [${modules_ref[*]}] (PHP ${phpver_raw}), CageFS/selector steps skipped"
    fi
}

install_module_flow() {
    PENDING_MODULES=()

    step_header "Select Modules"
    info "You can select multiple modules; they'll be installed together with a single CageFS refresh at the end."

    while true; do
        select_module_from_list MODULE
        PENDING_MODULES+=("$MODULE")
        log "Added to batch: ${BOLD}$MODULE${NC} ${DIM}(${#PENDING_MODULES[@]} module(s) queued)${NC}"
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Add another module?${NC} ${DIM}(y/n)${NC}: ")" ADD_MORE
        [[ "$ADD_MORE" == "y" || "$ADD_MORE" == "Y" ]] || break
    done

    step_header "PHP Version"
    read_php_version "Enter PHP version" PHPVER_RAW
    PHPVER=$(echo "$PHPVER_RAW" | tr -d '.')

    step_header "Locating PHP Installation(s)"
    select_php_targets "$PHPVER" "no" || return 1

    if [[ ${#PENDING_MODULES[@]} -gt 1 || ${#SELECTED_PHP_TARGETS[@]} -gt 1 ]]; then
        info "Installing across multiple modules/targets is heavier on CageFS — consider running this during low-traffic hours."
    fi

    SUCCESSFUL_MODULES=()
    FAILED_MODULES=()

    local target k r
    for target in "${SELECTED_PHP_TARGETS[@]}"; do
        IFS=':' read -r k r <<< "$target"

        step_header "Target: ${r} (${k})"

        if [[ "$k" == "ea" ]]; then
            PANEL="cpanel"
            PKG_PREFIX="ea-php${PHPVER}-php-"
        else
            PANEL="directadmin"
            PKG_PREFIX="alt-php${PHPVER}-"
        fi

        for mod in "${PENDING_MODULES[@]}"; do
            MODULE="$mod"
            if install_one_module_package "$MODULE"; then
                SUCCESSFUL_MODULES+=("$INSTALLED_MODULE_NAME")
            else
                FAILED_MODULES+=("$mod (${k})")
            fi
        done
    done

    check_cagefs_status
    check_is_cloudlinux
    run_post_install_tasks SUCCESSFUL_MODULES "$PHPVER_RAW"

    separator
    if [[ ${#SUCCESSFUL_MODULES[@]} -gt 0 ]]; then
        echo -e "${BOLD}${GREEN}✔ Installed: ${SUCCESSFUL_MODULES[*]}${NC}"
    fi
    if [[ ${#FAILED_MODULES[@]} -gt 0 ]]; then
        echo -e "${BOLD}${RED}✘ Failed/cancelled: ${FAILED_MODULES[*]}${NC}"
    fi
    separator
}

user_info_flow() {
    while true; do
        step_header "User Information"
        echo -e "  ${CYAN}1)${NC} Current PHP version for a user"
        echo -e "  ${CYAN}2)${NC} Enabled extensions for a user"
        echo -e "  ${CYAN}3)${NC} List all users on a PHP version"
        echo -e "  ${CYAN}4)${NC} Get LVE ID for a user"
        echo -e "  ${CYAN}0)${NC} Back to main menu"
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Choose an option${NC}: ")" INFO_CHOICE

        case "$INFO_CHOICE" in
            1)
                read_username USERNAME
                echo ""
                info "Current PHP version for user ${BOLD}$USERNAME${NC}:"
                selectorctl --user-current --user="$USERNAME" 2>&1 | sed 's/^/  /'
                ;;
            2)
                read_username USERNAME
                read_php_version "Enter PHP version" PHPVER_RAW
                echo ""
                info "Enabled extensions for user ${BOLD}$USERNAME${NC} on PHP ${BOLD}$PHPVER_RAW${NC}:"
                selectorctl --list-user-extensions --version="$PHPVER_RAW" --user="$USERNAME" 2>&1 | sed 's/^/  /'
                ;;
            3)
                read_php_version "Enter PHP version" PHPVER_RAW
                echo ""
                info "Users on PHP ${BOLD}$PHPVER_RAW${NC}:"
                selectorctl --list-users --version="$PHPVER_RAW" 2>&1 | sed 's/^/  /'
                ;;
            4)
                read_username USERNAME
                echo ""
                info "LVE ID for user ${BOLD}$USERNAME${NC}:"
                local lve_id
                lve_id=$(id -u "$USERNAME" 2>/dev/null)
                if [[ -n "$lve_id" ]]; then
                    log "LVE ID: ${BOLD}$lve_id${NC} ${DIM}(standard CloudLinux setups map LVE ID to the account's UID)${NC}"
                else
                    err "Could not resolve an ID for '$USERNAME'."
                fi
                ;;
            0)
                info "Returning to main menu."
                return 0
                ;;
            *)
                err "Invalid option."
                ;;
        esac

        separator
    done
}

manage_user_flow() {
    step_header "Manage PHP Settings"

    echo -e "  ${CYAN}1)${NC} Change PHP version for a specific user"
    echo -e "  ${CYAN}2)${NC} Change PHP version for all users ⚠️"
    echo -e "  ${CYAN}3)${NC} Enable a module for a specific user"
    echo -e "  ${CYAN}4)${NC} Enable a module for all users ⚠️"
    echo -e "  ${CYAN}5)${NC} Disable a module for a specific user"
    echo -e "  ${CYAN}6)${NC} Disable a module for all users ⚠️"
    echo -e "  ${CYAN}0)${NC} Back to main menu"
    read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Choose an option${NC}: ")" SUBCHOICE

    case "$SUBCHOICE" in
        1)
            read_username USERNAME
            read_php_version "Enter new PHP version" PHPVER_RAW
            run_cmd "set-user-current=$PHPVER_RAW for $USERNAME" \
                selectorctl --set-user-current="$PHPVER_RAW" --user="$USERNAME"
            audit_log "Changed PHP version to ${PHPVER_RAW} for user '${USERNAME}'"
            ;;
        2)
            read_php_version "Enter new PHP version" PHPVER_RAW
            if confirm_all_users "change the PHP version to ${PHPVER_RAW}"; then
                run_cmd "set-user-current=$PHPVER_RAW for all users" \
                    selectorctl --set-user-current="$PHPVER_RAW" --for-all-users
                audit_log "Changed PHP version to ${PHPVER_RAW} for ALL USERS"
            else
                info "Cancelled."
            fi
            ;;
        3)
            read_username USERNAME
            select_module_from_list MODULE
            read_php_version "Enter PHP version" PHPVER_RAW
            enable_selector_extension "$MODULE" "$PHPVER_RAW" "user" "$USERNAME"
            audit_log "Enabled module '${MODULE}' (PHP ${PHPVER_RAW}) for user '${USERNAME}'"
            ;;
        4)
            select_module_from_list MODULE
            read_php_version "Enter PHP version" PHPVER_RAW
            if confirm_all_users "enable '${MODULE}'"; then
                enable_selector_extension "$MODULE" "$PHPVER_RAW" "all"
                audit_log "Enabled module '${MODULE}' (PHP ${PHPVER_RAW}) for ALL USERS"
            else
                info "Cancelled."
            fi
            ;;
        5)
            read_username USERNAME
            select_module_from_list MODULE
            read_php_version "Enter PHP version" PHPVER_RAW
            disable_selector_extension "$MODULE" "$PHPVER_RAW" "user" "$USERNAME"
            audit_log "Disabled module '${MODULE}' (PHP ${PHPVER_RAW}) for user '${USERNAME}'"
            ;;
        6)
            select_module_from_list MODULE
            read_php_version "Enter PHP version" PHPVER_RAW
            if confirm_all_users "disable '${MODULE}'"; then
                disable_selector_extension "$MODULE" "$PHPVER_RAW" "all"
                audit_log "Disabled module '${MODULE}' (PHP ${PHPVER_RAW}) for ALL USERS"
            else
                info "Cancelled."
            fi
            ;;
        0)
            info "Returning to main menu."
            return 0
            ;;
        *)
            err "Invalid option."
            ;;
    esac

    separator
}

system_diagnostics_flow() {
    while true; do
        step_header "System Diagnostics & Maintenance"
        echo -e "  ${CYAN}1)${NC} CageFS Sanity Check"
        echo -e "  ${CYAN}2)${NC} CageFS Status"
        echo -e "  ${CYAN}3)${NC} List LVE Limits (all users)"
        echo -e "  ${CYAN}4)${NC} LVE Usage Info (last 1 day, all users)"
        echo -e "  ${CYAN}5)${NC} LVE Usage Info for a Specific User"
        echo -e "  ${CYAN}6)${NC} Clean Old CageFS Data ⚠️"
        echo -e "  ${CYAN}7)${NC} Selector Summary"
        echo -e "  ${CYAN}8)${NC} Full CageFS Refresh (force-update + remount-all + rebuild ini + update etc)"
        echo -e "  ${CYAN}9)${NC} Top 5 Resource Consumers (real-time)"
        echo -e "  ${CYAN}0)${NC} Back to main menu"
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Choose an option${NC}: ")" DIAG_CHOICE

        case "$DIAG_CHOICE" in
            1)
                info "Running CageFS sanity check..."
                echo ""
                cagefsctl --sanity-check 2>&1 | awk '
                    /^Check/ { printf "  \033[0;36m➜\033[0m %s\n", $0; next }
                    /OK:/    { printf "    \033[0;32m✔\033[0m %s\n", $0; next }
                    /SKIPPED:/ { printf "    \033[1;33m~\033[0m %s\n", $0; next }
                    /ERROR:|FAIL/ { printf "    \033[0;31m✘\033[0m %s\n", $0; next }
                    /errors found/ { printf "\n  \033[1m%s\033[0m\n", $0; next }
                    /^$/     { next }
                    { print "  " $0 }
                '
                ;;
            2)
                info "CageFS status:"
                cagefsctl --cagefs-status 2>&1 | sed 's/^/  /'
                ;;
            3)
                info "LVE limits for all users:"
                echo ""
                if command -v column &>/dev/null; then
                    lvectl list 2>&1 | column -t | awk 'NR==1 {print "  \033[1m\033[0;36m" $0 "\033[0m"; next} {print "  " $0}'
                else
                    lvectl list 2>&1 | awk 'NR==1 {print "  \033[1m\033[0;36m" $0 "\033[0m"; next} {print "  " $0}'
                fi
                ;;
            4)
                info "LVE usage info (last 1 day):"
                lveinfo --period=1d 2>&1 | sed 's/^/  /'
                ;;
            5)
                read_username USERNAME
                info "LVE usage info for ${BOLD}$USERNAME${NC}:"
                lveinfo --user="$USERNAME" 2>&1 | sed 's/^/  /'
                ;;
            6)
                warn "This will remove old/cached CageFS data. It is generally safe but may briefly affect users."
                read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Proceed with cleaning old CageFS data? ⚠️${NC} ${DIM}(y/n)${NC}: ")" CLEAN_CONFIRM
                if [[ "$CLEAN_CONFIRM" == "y" || "$CLEAN_CONFIRM" == "Y" ]]; then
                    run_cmd "cagefsctl --clean-var-cagefs" cagefsctl --clean-var-cagefs
                    audit_log "Ran cagefsctl --clean-var-cagefs"
                else
                    info "Cancelled."
                fi
                ;;
            7)
                info "Selector summary:"
                selectorctl --summary 2>&1 | sed 's/^/  /'
                ;;
            8)
                run_cmd "force update"    cagefsctl --force-update
                run_cmd "remount all"     cagefsctl --remount-all
                run_cmd "rebuild php ini" cagefsctl --rebuild-alt-php-ini
                run_cmd "update etc"      cagefsctl --force-update-etc
                audit_log "Ran Full CageFS Refresh (force-update + remount-all + rebuild ini + update etc)"
                ;;
            9)
                info "Top 5 resource consumers right now:"
                echo ""
                if command -v lvetop &>/dev/null; then
                    timeout 5 lvetop -s cpu -x 2>/dev/null | awk 'NR==1 {print "  \033[1m\033[0;36m" $0 "\033[0m"; next} NR<=6 {print "  " $0}'
                elif command -v lveps &>/dev/null; then
                    timeout 5 lveps -s cpu -x 2>/dev/null | awk 'NR==1 {print "  \033[1m\033[0;36m" $0 "\033[0m"; next} NR<=6 {print "  " $0}'
                else
                    warn "lvetop/lveps not found, falling back to lveinfo (last 1h)."
                    if command -v column &>/dev/null; then
                        lveinfo --period=1h 2>&1 | column -t | awk 'NR==1 {print "  \033[1m\033[0;36m" $0 "\033[0m"; next} NR<=6 {print "  " $0}'
                    else
                        lveinfo --period=1h 2>&1 | awk 'NR==1 {print "  \033[1m\033[0;36m" $0 "\033[0m"; next} NR<=6 {print "  " $0}'
                    fi
                fi
                ;;
            0)
                info "Returning to main menu."
                return 0
                ;;
            *)
                err "Invalid option."
                ;;
        esac
    done
}

install_loaders_flow() {
    step_header "ionCube & SourceGuardian"
    warn "This installs official CloudLinux-packaged loaders. Newer PHP versions may require the testing repo."

    echo -e "  ${CYAN}1)${NC} ionCube Loader only"
    echo -e "  ${CYAN}2)${NC} SourceGuardian only"
    echo -e "  ${CYAN}3)${NC} Both"
    read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Choose an option${NC}: ")" LOADER_CHOICE

    case "$LOADER_CHOICE" in
        1) LOADERS=("ioncube-loader"); SELECTOR_NAMES=("ioncube_loader") ;;
        2) LOADERS=("sourceguardian"); SELECTOR_NAMES=("sourceguardian") ;;
        3) LOADERS=("ioncube-loader" "sourceguardian"); SELECTOR_NAMES=("ioncube_loader" "sourceguardian") ;;
        *) err "Invalid option."; return 1 ;;
    esac

    read_php_version "Enter PHP version" PHPVER_RAW
    PHPVER=$(echo "$PHPVER_RAW" | tr -d '.')

    step_header "Locating PHP Installation(s)"
    info "ionCube/SourceGuardian packages exist for both alt-php and ea-php — checking both."
    select_php_targets "$PHPVER" "no" || return 1

    local overall_installed_any=false

    local target k r
    for target in "${SELECTED_PHP_TARGETS[@]}"; do
        IFS=':' read -r k r <<< "$target"

        step_header "Target: ${r} (${k})"

        if [[ "$k" == "ea" ]]; then
            PKG_PREFIX="ea-php${PHPVER}-php-"
        else
            PKG_PREFIX="alt-php${PHPVER}-"
        fi

        for pkg_suffix in "${LOADERS[@]}"; do
            FULL_PKG="${PKG_PREFIX}${pkg_suffix}"

            info "Installing ${FULL_PKG}"

            if rpm -q "$FULL_PKG" &>/dev/null; then
                log "Already installed: ${BOLD}$FULL_PKG${NC}"
                overall_installed_any=true
                continue
            fi

            if install_package_with_testing_fallback "$FULL_PKG" "yes"; then
                overall_installed_any=true
            else
                warn "Failed to install $FULL_PKG on this target (may simply not be offered for ${k}-php). Skipping."
            fi
        done
    done

    if ! $overall_installed_any; then
        err "No loader packages could be installed on any detected target."
        return 1
    fi

    check_cagefs_status
    check_is_cloudlinux
    run_post_install_tasks SELECTOR_NAMES "$PHPVER_RAW"

    separator
    echo -e "${BOLD}${GREEN}✔ ionCube & SourceGuardian setup completed.${NC}"
    separator
}

ZEND_EXTENSION_MODULES=("ioncube_loader" "sourceguardian")

declare -A MODULE_VERIFY_PATTERNS=(
    [opcache]="opcache"
    [ioncube_loader]="ioncube"
    [sourceguardian]="sourceguardian"
)

verify_module_loaded() {
    local php_bin="$1" module="$2"

    if [[ ! -x "$php_bin" ]]; then
        return 2
    fi

    local pattern="${MODULE_VERIFY_PATTERNS[$module]:-}"
    if [[ -n "$pattern" ]]; then
        "$php_bin" -m 2>/dev/null | grep -qi "$pattern" && return 0
        "$php_bin" -v 2>/dev/null | grep -qi "$pattern" && return 0
        return 1
    fi

    "$php_bin" -m 2>/dev/null | grep -qi "^${module}$"
}

is_zend_extension_module() {
    local mod="$1"
    local z
    for z in "${ZEND_EXTENSION_MODULES[@]}"; do
        [[ "$z" == "$mod" ]] && return 0
    done
    return 1
}

download_native_loader() {
    local module="$1" phpver_raw="$2" chosen_root="$3"

    local dl_tool=""
    if command -v wget &>/dev/null; then
        dl_tool="wget"
    elif command -v curl &>/dev/null; then
        dl_tool="curl"
    else
        err "Neither wget nor curl found — cannot download automatically."
        return 1
    fi

    local arch
    arch=$(uname -m)
    local url=""
    if [[ "$module" == "ioncube_loader" ]]; then
        if [[ "$arch" == "aarch64" ]]; then
            url="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_aarch64.tar.gz"
        else
            url="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
        fi
    elif [[ "$module" == "sourceguardian" ]]; then
        if [[ "$arch" == "aarch64" ]]; then
            url="https://www.sourceguardian.com/loaders/download/loaders.linux-aarch64.tar.gz"
        else
            url="https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz"
        fi
    else
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d /tmp/php-manager-loader.XXXXXX) || { err "Could not create a temp directory."; return 1; }

    info "Downloading from: $url"
    if [[ "$dl_tool" == "wget" ]]; then
        run_cmd "wget loader package" wget -q -O "$tmpdir/loader.tar.gz" "$url" || { rm -rf "$tmpdir"; return 1; }
    else
        run_cmd "curl loader package" curl -fsSL -o "$tmpdir/loader.tar.gz" "$url" || { rm -rf "$tmpdir"; return 1; }
    fi

    run_cmd "extract loader package" tar -xzf "$tmpdir/loader.tar.gz" -C "$tmpdir" || { rm -rf "$tmpdir"; return 1; }

    local found_so=""
    if [[ "$module" == "ioncube_loader" ]]; then
        found_so=$(find "$tmpdir" -iname "ioncube_loader_lin_${phpver_raw}.so" 2>/dev/null | head -n1)
    else
        found_so=$(find "$tmpdir" -iname "ixed.${phpver_raw}.lin" 2>/dev/null | head -n1)
    fi

    if [[ -z "$found_so" ]]; then
        err "No loader file matching PHP ${phpver_raw} was found inside the downloaded package."
        rm -rf "$tmpdir"
        return 1
    fi

    local dest_dir=""
    if [[ -d "${chosen_root}/lib/php/extensions" ]]; then
        dest_dir=$(find "${chosen_root}/lib/php/extensions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | tail -n1)
    fi
    [[ -z "$dest_dir" ]] && dest_dir="${chosen_root}/lib"
    mkdir -p "$dest_dir" 2>/dev/null

    local dest_file="${dest_dir}/$(basename "$found_so")"
    if ! cp "$found_so" "$dest_file"; then
        err "Failed to copy loader file to $dest_file"
        rm -rf "$tmpdir"
        return 1
    fi
    chmod 755 "$dest_file"
    rm -rf "$tmpdir"

    log "Loader placed at: ${BOLD}$dest_file${NC}"
    NATIVE_LOADER_SO_PATH="$dest_file"
    return 0
}

manual_extension_flow() {
    step_header "Manual Extension Enable (beta)"
    info "Fully standalone mode: works even without going through option 1 first, and even if CageFS is off or PHP is native."

    local module=""
    while [[ -z "$module" ]] || ! [[ "$module" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; do
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Enter the extension name${NC} ${DIM}(e.g. gd, ioncube_loader)${NC}: ")" module
        if ! [[ "$module" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            err "Invalid name. Use letters, numbers, underscore only."
            module=""
        fi
    done

    read_php_version "Enter PHP version" PHPVER_RAW
    local phpver
    phpver=$(echo "$PHPVER_RAW" | tr -d '.')

    step_header "Locating PHP Installation"

    detect_php_installations "$phpver"
    local candidates=("${PHP_INSTALL_CANDIDATES[@]}")

    if [[ ${#candidates[@]} -eq 0 ]]; then
        err "No PHP ${PHPVER_RAW} installation found under /opt/alt, /opt/cpanel/ea-php*, or /usr/local."
        return 1
    fi

    local chosen_root="" chosen_kind=""
    if [[ ${#candidates[@]} -eq 1 ]]; then
        IFS=':' read -r chosen_kind chosen_root <<< "${candidates[0]}"
        log "Found one PHP ${PHPVER_RAW} installation: ${BOLD}$chosen_root${NC} ${DIM}(${chosen_kind})${NC}"
    else
        warn "Multiple PHP ${PHPVER_RAW} installations found on this server — panel detection alone can't tell which one your sites actually use:"
        local i=1 c k r
        for c in "${candidates[@]}"; do
            IFS=':' read -r k r <<< "$c"
            echo -e "  ${CYAN}${i})${NC} $r ${DIM}(${k})${NC}"
            i=$((i+1))
        done
        local pick=""
        while true; do
            read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Select installation number${NC}: ")" pick
            if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#candidates[@]} )); then
                IFS=':' read -r chosen_kind chosen_root <<< "${candidates[$((pick-1))]}"
                break
            fi
            err "Invalid selection."
        done
    fi

    local ini_dir php_bin
    if [[ "$chosen_kind" == "native" ]]; then
        if [[ -d "${chosen_root}/lib/php.conf.d" ]]; then
            ini_dir="${chosen_root}/lib/php.conf.d"
        else
            ini_dir="${chosen_root}/lib"
        fi
        php_bin="${chosen_root}/bin/php"
    else
        ini_dir="${chosen_root}/etc/php.d"
        php_bin="${chosen_root}/usr/bin/php"
    fi

    if verify_module_loaded "$php_bin" "$module"; then
        log "${BOLD}${GREEN}'$module' is already active on PHP ${PHPVER_RAW} — nothing to do.${NC}"
        return 0
    fi

    step_header "Locating .so File"

    local so_path
    so_path=$(find "$chosen_root" -iname "${module}.so" 2>/dev/null | head -n1)

    if [[ -z "$so_path" ]]; then
        warn "'${module}.so' was not found anywhere under $chosen_root."

        if [[ "$chosen_kind" == "native" ]]; then
            if is_zend_extension_module "$module"; then
                info "No prebuilt loader found on disk, but ${module} is distributed as an official precompiled binary (no compilation needed)."
                read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Download and install the official loader now?${NC} ${DIM}(y/n)${NC}: ")" try_download
                if [[ "$try_download" != "y" && "$try_download" != "Y" ]]; then
                    info "Cancelled."
                    return 0
                fi

                if download_native_loader "$module" "$PHPVER_RAW" "$chosen_root"; then
                    so_path="$NATIVE_LOADER_SO_PATH"
                else
                    err "Automatic download/install failed."
                    info "Manual fallback — download yourself and place under ${chosen_root}, then run this option again:"
                    info "ionCube: https://www.ioncube.com/loaders.php"
                    info "SourceGuardian: https://www.sourceguardian.com/loaders/"
                    return 1
                fi
            else
                err "This is a native PHP build — there's no package manager to install extensions from."
                info "Non-loader extensions (like '${module}') need to be compiled from source (PECL) to match this exact PHP build."
                info "This script can't safely automate that — install it manually, then run this option again to write the ini."
                return 1
            fi
        else
            read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Try to find and install a package for '${module}' now?${NC} ${DIM}(y/n)${NC}: ")" try_install
            if [[ "$try_install" != "y" && "$try_install" != "Y" ]]; then
                info "Cancelled."
                return 0
            fi

            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi

            PHPVER="$phpver"
            if [[ "$chosen_kind" == "ea" ]]; then
                PANEL="cpanel"
                PKG_PREFIX="ea-php${phpver}-php-"
            else
                PANEL="directadmin"
                PKG_PREFIX="alt-php${phpver}-"
            fi

            install_one_module_package "$module" || {
                err "Could not install a package for '$module'. Nothing more manual mode can automate here."
                return 1
            }

            so_path=$(find "$chosen_root" -iname "${module}.so" 2>/dev/null | head -n1)

            if [[ -z "$so_path" ]]; then
                err "Package installed, but no '${module}.so' file was found afterward."
                info "This module may be compiled into a different core file, or the package uses a different .so name."
                return 1
            fi

            if verify_module_loaded "$php_bin" "$module"; then
                log "${BOLD}${GREEN}'$module' is already active after the package install — nothing more to do.${NC}"
                audit_log "Installed '${module}' (PHP ${PHPVER_RAW}) via manual mode; package already activated it"
                return 0
            fi
        fi
    fi

    log "Found: ${BOLD}$so_path${NC}"

    local directive="extension"
    if is_zend_extension_module "$module"; then
        directive="zend_extension"
    fi
    info "Will write: ${BOLD}${directive}=${so_path}${NC}"

    step_header "Writing Configuration"

    if [[ ! -d "$ini_dir" ]]; then
        err "Expected config directory not found: $ini_dir"
        return 1
    fi

    local ini_file="${ini_dir}/${module}.ini"
    local backup=""

    if [[ -f "$ini_file" ]]; then
        warn "An ini file already exists at $ini_file:"
        echo -e "${DIM}"
        sed 's/^/    /' "$ini_file"
        echo -e "${NC}"
        read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Overwrite it?${NC} ${DIM}(y/n)${NC}: ")" overwrite_confirm
        if [[ "$overwrite_confirm" != "y" && "$overwrite_confirm" != "Y" ]]; then
            info "Cancelled."
            return 0
        fi
        backup="${ini_file}.bak-$(date +%Y%m%d%H%M%S)"
        cp "$ini_file" "$backup"
        log "Backed up existing file to $backup"
    fi

    read -rp "$(echo -e "  ${YELLOW}${BOLD}➜ Write '${directive}=${so_path}' to ${ini_file}?${NC} ${DIM}(y/n)${NC}: ")" write_confirm
    if [[ "$write_confirm" != "y" && "$write_confirm" != "Y" ]]; then
        info "Cancelled."
        return 0
    fi

    if ! echo "${directive}=${so_path}" > "$ini_file"; then
        err "Failed to write $ini_file. Check permissions."
        return 1
    fi
    log "Written: $ini_file"

    step_header "Verifying"

    if [[ -x "$php_bin" ]]; then
        if verify_module_loaded "$php_bin" "$module"; then
            log "${BOLD}${GREEN}'$module' is now active on PHP ${PHPVER_RAW}.${NC}"
        else
            err "'$module' still not showing in 'php -m'/'php -v' after writing the ini."
            warn "Reverting — this configuration doesn't seem to work for this build."
            if [[ -n "$backup" && -f "$backup" ]]; then
                mv "$backup" "$ini_file"
                info "Restored the previous file."
            else
                rm -f "$ini_file"
                info "Removed the file we just created."
            fi
            return 1
        fi
    else
        warn "Could not find a php binary at $php_bin to verify. Please check manually."
    fi

    audit_log "Manually enabled '${module}' (PHP ${PHPVER_RAW}) via ${ini_file} [${chosen_kind}]"

    if [[ "$chosen_kind" == "native" ]]; then
        warn "Native PHP build — no CageFS/selectorctl involved here."
        info "Restart your web server to apply the change, e.g.: systemctl restart httpd  (or lsws)"
    else
        check_cagefs_status
        check_is_cloudlinux
        local single_module_array=("$module")
        run_post_install_tasks single_module_array "$PHPVER_RAW"
    fi

    separator
    echo -e "${BOLD}${GREEN}✔ Manual extension setup completed.${NC}"
    separator
}

main_menu() {
    while true; do
        banner
        echo -e "  ${CYAN}1)${NC} Install Module"
        echo -e "  ${CYAN}2)${NC} User Info"
        echo -e "  ${CYAN}3)${NC} Manage User PHP Settings"
        echo -e "  ${CYAN}4)${NC} System Diagnostics & Maintenance"
        echo -e "  ${CYAN}5)${NC} ionCube & SourceGuardian"
        echo -e "  ${CYAN}6)${NC} Manual Extension Enable (beta)"
        echo -e "  ${CYAN}7)${NC} Exit"
        echo ""
        read -rp "$(echo -e "  ${MAGENTA}${BOLD}➜ Select an option${NC}: ")" CHOICE

        case "$CHOICE" in
            1) install_module_flow ;;
            2) user_info_flow ;;
            3) manage_user_flow ;;
            4) system_diagnostics_flow ;;
            5) install_loaders_flow ;;
            6) manual_extension_flow ;;
            7) echo -e "${GREEN}Goodbye.${NC}"; exit 0 ;;
            *) err "Invalid option." ;;
        esac
    done
}

main_menu
