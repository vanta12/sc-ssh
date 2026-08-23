#!/usr/bin/env bash
# ============================================================
#  users.sh — Multi-user trial management
# ============================================================

USER_DB="${AUTOSCRIPT_ROOT:-/opt/autoscript}/data/users.db"
USER_LOG="${AUTOSCRIPT_ROOT:-/opt/autoscript}/logs/vpn-users.log"

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

    # Generate random username if not provided
    if [ -z "$username" ]; then
        local prefix
        prefix=$(random_str 4 | tr '[:upper:]' '[:lower:]')
        local suffix
        suffix=$(random_num 10 99)
        username="${prefix}${suffix}"
    fi

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

    # Create system user (no shell, no home)
    useradd -M -s /bin/false "$username" 2>/dev/null || {
        useradd -M -s /usr/sbin/nologin "$username" 2>/dev/null || {
            err "Gagal membuat user: $username"
            return 1
        }
    }

    # Set password
    echo "${username}:${password}" | chpasswd 2>/dev/null || {
        warn "Gagal set password untuk $username"
    }

    # Store only a password hash. Cleartext password is returned once above.
    if ! command -v openssl >/dev/null 2>&1; then
        install_pkg openssl
    fi
    local password_hash
    password_hash=$(openssl passwd -6 "$password") || die "Gagal membuat password hash"
    echo "${username}|${password_hash}|$(date '+%Y-%m-%d %H:%M:%S')|${expire_date}|${duration_hours}" >> "$USER_DB"

    # Schedule deletion via cron (at)
    if command -v at &>/dev/null; then
        echo "bash ${AUTOSCRIPT_USER_HELPER:-/opt/autoscript/runtime/lib/06-users.sh} user-delete ${username}" | at now + "${duration_hours}" hours 2>/dev/null
    fi

    # Also setup cron checker
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

    # Remove from DB
    if [ -f "$USER_DB" ]; then
        sed -i "/^${username}|/d" "$USER_DB" 2>/dev/null || true
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

users_menu() {
    while true; do
        clear
        banner
        echo ""
        echo -e "${BOLD}${CYAN}  USER MANAGEMENT MENU${NC}"
        echo ""
        echo "  [1] Create trial user"
        echo "  [2] List active users"
        echo "  [3] Delete user"
        echo "  [4] Extend user"
        echo "  [5] Purge all expired"
        echo "  [6] Back to main menu"
        echo ""
        read -rp "  Pilih [1-6]: " choice

        case "$choice" in
            1)
                echo ""
                echo "  Pilih durasi trial:"
                echo "    [1] 2 jam"
                echo "    [2] 6 jam"
                echo "    [3] 12 jam"
                echo "    [4] 1 hari"
                echo "    [5] 3 hari"
                echo "    [6] 7 hari"
                echo "    [7] Custom (jam)"
                read -rp "  > " dur_choice
                case "$dur_choice" in
                    1) HOURS=2 ;;
                    2) HOURS=6 ;;
                    3) HOURS=12 ;;
                    4) HOURS=24 ;;
                    5) HOURS=72 ;;
                    6) HOURS=168 ;;
                    7) read -rp "  Jam: " HOURS ;;
                    *) warn "Invalid, default 2 jam"; HOURS=2 ;;
                esac
                pass=$(users_create "$HOURS")
                if [ $? -eq 0 ]; then
                    info "User trial berhasil dibuat!"
                    echo "  Username: $(tail -1 "$USER_DB" | cut -d'|' -f1)"
                    echo "  Password: $pass"
                    echo "  Expire  : $HOURS jam"
                fi
                read -rp "  [Enter] lanjut..." _
                ;;
            2)
                users_list
                read -rp "  [Enter] lanjut..." _
                ;;
            3)
                read -rp "  Username: " uname
                users_delete "$uname"
                read -rp "  [Enter] lanjut..." _
                ;;
            4)
                read -rp "  Username: " uname
                read -rp "  Tambahan jam: " hours
                users_extend "$uname" "$hours"
                read -rp "  [Enter] lanjut..." _
                ;;
            5)
                users_purge_expired
                info "Semua expired user telah dihapus"
                read -rp "  [Enter] lanjut..." _
                ;;
            6)
                return
                ;;
            *)
                warn "Pilihan tidak valid"
                sleep 1
                ;;
        esac
    done
}

# ── CLI mode ───────────────────────────────────────────────
case "${1:-}" in
    user-create)
        users_create "${2:-2}" "${3:-}" "${4:-}"
        ;;
    user-delete)
        users_delete "${2:-}"
        ;;
    user-list)
        users_list
        ;;
    user-extend)
        users_extend "${2:-}" "${3:-0}"
        ;;
    user-purge-expired)
        users_purge_expired
        ;;
    user-menu)
        users_menu
        ;;
esac