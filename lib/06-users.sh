#!/usr/bin/env bash
# ============================================================
#  users.sh — Multi-user trial management
# ============================================================

USER_DB="${AUTOSCRIPT_ROOT:-/opt/autoscript}/data/users.db"
USER_LOG="${AUTOSCRIPT_ROOT:-/opt/autoscript}/logs/vpn-users.log"
COMMON_HELPER="${AUTOSCRIPT_COMMON_HELPER:-${AUTOSCRIPT_ROOT:-/opt/autoscript}/runtime/lib/common.sh}"
if ! declare -F random_str >/dev/null 2>&1; then
    [ -f "$COMMON_HELPER" ] || { printf 'common.sh tidak ditemukan\n' >&2; exit 1; }
    source "$COMMON_HELPER"
fi

users_init() {
    local data_dir
    data_dir="$(dirname "$USER_DB")"
    mkdir -p "$data_dir"
    chmod 700 "$data_dir"
    touch "$USER_DB"
    chmod 600 "$USER_DB"
}

users_create() {
    local duration_hours="${1:-2}"
    local username="${2:-}"
    local password="${3:-}"

    [[ "$duration_hours" =~ ^[1-9][0-9]*$ ]] || { err "Durasi user tidak valid"; return 1; }

    # Generate random username if not provided
    if [ -z "$username" ]; then
        local prefix
        prefix=$(random_str 4 | tr '[:upper:]' '[:lower:]')
        local suffix
        suffix=$(random_num 10 99)
        username="${prefix}${suffix}"
    fi
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
        err "Username tidak valid: $username"
        return 1
    }

    # Generate random password if not provided
    if [ -z "$password" ]; then
        password=$(random_str 12)
    fi

    # Calculate expiry
    local expire_date
    expire_date=$(date -d "+${duration_hours} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || \
        expire_date=$(date -d "+${duration_hours} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || \
        expire_date="manual"

    # Check if user already exists
    if id "$username" &>/dev/null; then
        warn "User '$username' sudah ada — skip"
        return 1
    fi

    # User needs valid shell for SSH forwarding and ssh -N.
    useradd -M -s /bin/bash "$username" 2>/dev/null || {
        err "Gagal membuat user: $username"
        return 1
    }
    track_user "$username"

    # Never record user whose password was not applied.
    if ! printf '%s:%s\n' "$username" "$password" | chpasswd 2>/dev/null; then
        userdel -f "$username" 2>/dev/null || true
        sed -i "\|^${username}$|d" "$AUTOSCRIPT_USER_MANIFEST" 2>/dev/null || true
        err "Gagal set password untuk $username"
        return 1
    fi

    # Store only a password hash. Cleartext password is returned once above.
    if ! command -v openssl >/dev/null 2>&1; then
        install_pkg openssl
    fi
    local password_hash
    password_hash=$(openssl passwd -6 "$password") || {
        userdel -f "$username" 2>/dev/null || true
        return 1
    }
    if ! printf '%s|%s|%s|%s|%s\n' "$username" "$password_hash" "$(date '+%Y-%m-%d %H:%M:%S')" "$expire_date" "$duration_hours" >> "$USER_DB"; then
        userdel -f "$username" 2>/dev/null || true
        return 1
    fi

    # Schedule deletion via cron (at)
    if command -v at &>/dev/null; then
        echo "bash ${AUTOSCRIPT_USER_HELPER:-/opt/autoscript/runtime/lib/06-users.sh} user-delete ${username}" | at now + "${duration_hours}" hours 2>/dev/null
    fi

    # Also setup cron checker
    track_file_before_write /etc/cron.d/vpn-expire
    cat > /etc/cron.d/vpn-expire <<CRON
# Check expired users every 10 minutes
*/10 * * * * root bash ${AUTOSCRIPT_USER_HELPER:-/opt/autoscript/runtime/lib/06-users.sh} user-purge-expired 2>/dev/null
CRON

    log "User created: $username (expires in ${duration_hours}h)"
    echo "$password"
    return 0
}

users_delete() {
    local username=$1
    if ! id "$username" &>/dev/null; then
        warn "User '$username' tidak ditemukan"
        return 1
    fi

    # Kill user processes
    pkill -u "$username" 2>/dev/null || true
    sleep 1

    # Delete user
    userdel -f "$username" 2>/dev/null || true

    # Remove from DB and AutoScript ownership manifest.
    if [ -f "$USER_DB" ]; then
        sed -i "/^${username}|/d" "$USER_DB" 2>/dev/null || true
    fi
    if [ -f "${AUTOSCRIPT_USER_MANIFEST:-}" ]; then
        sed -i "\|^${username}$|d" "$AUTOSCRIPT_USER_MANIFEST" 2>/dev/null || true
    fi

    log "User deleted: $username"
    return 0
}

users_purge_expired() {
    if [ ! -f "$USER_DB" ]; then return 0; fi

    local now
    now=$(date '+%s')

    while IFS='|' read -r username password created expire duration; do
        [ -z "$username" ] && continue
        local exp_ts
        exp_ts=$(date -d "$expire" '+%s' 2>/dev/null) || continue
        if [ "$now" -ge "$exp_ts" ]; then
            users_delete "$username"
            echo "$(date): Purged expired user $username (expired: $expire)" >> "$USER_LOG"
        fi
    done < "$USER_DB"
}

users_list() {
    if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
        info "Tidak ada user trial."
        return 0
    fi

    echo ""
    echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│  Username          Password        Created        Expires    │${NC}"
    echo -e "${BOLD}${CYAN}├──────────────────────────────────────────────────────────────┤${NC}"

    while IFS='|' read -r username password created expire duration; do
        [ -z "$username" ] && continue
        # Check if still exists
        if id "$username" &>/dev/null 2>&1; then
            local status="${GREEN}active${NC}"
        else
            local status="${RED}deleted${NC}"
        fi
        printf "│ ${CYAN}%-16s${NC} ${YELLOW}%-14s${NC} %-12s %-12s %s │\n" \
            "$username" "[hidden]" "${created:0:10}" "${expire:0:10}" "$status"
    done < "$USER_DB"

    echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

users_extend() {
    local username=$1
    local extra_hours=$2

    if ! id "$username" &>/dev/null; then
        warn "User '$username' tidak ditemukan"
        return 1
    fi

    # Update DB entry
    if [ -f "$USER_DB" ]; then
        local line
        line=$(grep "^${username}|" "$USER_DB" 2>/dev/null)
        if [ -n "$line" ]; then
            local old_expire
            old_expire=$(echo "$line" | cut -d'|' -f4)
            local new_expire
            new_expire=$(date -d "${old_expire} + ${extra_hours} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || \
                new_expire=$(date -d "+${extra_hours} hours" '+%Y-%m-%d %H:%M:%S')
            local old_dur
            old_dur=$(echo "$line" | cut -d'|' -f5)
            local new_dur=$((old_dur + extra_hours))
            local pass
            pass=$(echo "$line" | cut -d'|' -f2)
            local created
            created=$(echo "$line" | cut -d'|' -f3)

            # Remove old entry, add new
            sed -i "/^${username}|/d" "$USER_DB"
            echo "${username}|${pass}|${created}|${new_expire}|${new_dur}" >> "$USER_DB"
        fi
    fi

    log "User extended: $username (+${extra_hours}h)"
}

# Cron-only entry points. Installer has no interactive menu or subcommands.
case "${1:-}" in
    user-delete)
        users_delete "${2:-}"
        ;;
    user-purge-expired)
        users_purge_expired
        ;;
esac