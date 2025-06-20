#!/bin/bash

set -e

CONFIG_FILE="$(dirname "$0")/sync_universal.conf"
LOG_FILE="$(dirname "$0")/sync_universal.log"

# --- Функции ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

get_package_manager() {
    if check_command apt; then echo "apt"; return; fi
    if check_command dnf; then echo "dnf"; return; fi
    if check_command yum; then echo "yum"; return; fi
    if check_command zypper; then echo "zypper"; return; fi
    echo "unsupported"
}

install_package() {
    local pkg="$1"
    local mgr
    mgr=$(get_package_manager)
    case $mgr in
        apt) sudo apt-get update && sudo apt-get install -y "$pkg" ;;
        dnf) sudo dnf install -y "$pkg" ;;
        yum) sudo yum install -y "$pkg" ;;
        zypper) sudo zypper install -y "$pkg" ;;
        *) log "[ОШИБКА] Неизвестный пакетный менеджер!"; exit 1 ;;
    esac
}

check_sudo_nopass() {
    if sudo -n true 2>/dev/null; then return 0; else return 1; fi
}

parse_config() {
    local section="$1"
    local key="$2"
    awk -F= -v section="[$section]" -v key="$key" '
        $0==section {found=1; next}
        found && $1==key {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}
    ' "$CONFIG_FILE"
}

ensure_deps() {
    local host="$1" user="$2" pass="$3"
    log "[ШАГ] Проверка зависимостей на $host..."
    for cmd in rsync sshpass psql sed pg_basebackup; do
        sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$host" "\
            if ! command -v $cmd >/dev/null 2>&1; then \
                echo 'Устанавливаю $cmd...'; \
                if command -v apt >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y $cmd; \
                elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y $cmd; \
                elif command -v yum >/dev/null 2>&1; then sudo yum install -y $cmd; \
                elif command -v zypper >/dev/null 2>&1; then sudo zypper install -y $cmd; \
                else echo '[ОШИБКА] Неизвестный пакетный менеджер!'; exit 1; fi; \
            fi"
    done
}

ensure_replication_user_and_hba() {
    local main_ssh_host="$1" main_ssh_user="$2" main_ssh_pass="$3" main_pg_conf_dir="$4" main_pg_user="$5" main_pg_pass="$6" rep_user="$7" rep_pass="$8" backup_ip="$9"
    log "[ШАГ] Настройка пользователя '$rep_user' для репликации на основном сервере..."

    # Пытаемся создать пользователя. Ошибку (если он уже есть) игнорируем.
    local create_sql="CREATE ROLE \"$rep_user\" WITH REPLICATION LOGIN ENCRYPTED PASSWORD '$rep_pass';"
    sshpass -p "$main_ssh_pass" ssh -o StrictHostKeyChecking=no "$main_ssh_user@$main_ssh_host" \
        "PGPASSWORD='$main_pg_pass' psql -h localhost -U '$main_pg_user' -d postgres -c \"$create_sql\"" \
        || log "[ИНФО] Не удалось создать пользователя '$rep_user' (вероятно, уже существует)."

    # В любом случае устанавливаем актуальный пароль.
    local alter_sql="ALTER ROLE \"$rep_user\" WITH PASSWORD '$rep_pass';"
    sshpass -p "$main_ssh_pass" ssh -o StrictHostKeyChecking=no "$main_ssh_user@$main_ssh_host" \
        "PGPASSWORD='$main_pg_pass' psql -h localhost -U '$main_pg_user' -d postgres -c \"$alter_sql\""
    log "[ИНФО] Пароль для пользователя '$rep_user' успешно установлен."

    log "[ШАГ] Проверка pg_hba.conf для репликации..."
    local hba_string="host    replication     $rep_user    $backup_ip/32    md5"
    sshpass -p "$main_ssh_pass" ssh -o StrictHostKeyChecking=no "$main_ssh_user@$main_ssh_host" "grep -qF \"$hba_string\" \"$main_pg_conf_dir/pg_hba.conf\" || echo \"$hba_string\" | sudo tee -a \"$main_pg_conf_dir/pg_hba.conf\""
    
    log "[ШАГ] Перезагрузка конфигурации PostgreSQL на основном сервере..."
    sshpass -p "$main_ssh_pass" ssh -o StrictHostKeyChecking=no "$main_ssh_user@$main_ssh_host" "sudo systemctl reload postgresql || sudo service postgresql reload"
}

manage_service() {
    local action="$1" host="$2" user="$3" pass="$4" service="$5"
    log "[ШАГ] ${action} сервиса $service на $host..."
    local command="stop"
    if [ "$action" == "Запуск" ]; then
        command="start"
    fi
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$host" "sudo systemctl $command \"$service\" || sudo service \"$service\" $command"
}

manage_postgres() {
    local action="$1" host="$2" user="$3" pass="$4"
    log "[ШАГ] ${action} PostgreSQL на $host..."
    local command="stop"
    if [ "$action" == "Запуск" ]; then
        command="start"
    fi
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$host" "sudo systemctl $command postgresql || sudo service postgresql $command"
}

rsync_app_data() {
    local src_host="$1" src_user="$2" src_pass="$3" src_path="$4"
    local dst_host="$5" dst_user="$6" dst_pass="$7" dst_path="$8"
    log "[ШАГ] Копирую данные приложения с $src_host на $dst_host..."
    
    # Создаём временную директорию на машине, где запущен скрипт
    local tmp_dir
    tmp_dir=$(mktemp -d)
    log "[ИНФО] Временная директория: $tmp_dir"

    # Копируем с основного сервера во временную директорию
    sshpass -p "$src_pass" rsync -a --delete -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$src_user@$src_host:$src_path/" "$tmp_dir/"
    
    # Копируем из временной директории на резервный сервер
    sshpass -p "$dst_pass" rsync -a --delete -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$tmp_dir/" "$dst_user@$dst_host:$dst_path/"
    
    # Удаляем временную директорию
    rm -rf "$tmp_dir"
    log "[ИНФО] Временная директория удалена."
}

run_pg_basebackup() {
    local backup_ssh_host="$1" backup_ssh_user="$2" backup_ssh_pass="$3" backup_pg_data_dir="$4" rep_user="$5" rep_pass="$6" main_ssh_host="$7"
    log "[ШАГ] Копирую кластер PostgreSQL через pg_basebackup..."
    sshpass -p "$backup_ssh_pass" ssh -o StrictHostKeyChecking=no "$backup_ssh_user@$backup_ssh_host" "
        sudo rm -rf \"$backup_pg_data_dir\"/*
        PGPASSWORD='$rep_pass' pg_basebackup -h '$main_ssh_host' -U '$rep_user' -D '$backup_pg_data_dir' -Fp -Xs -P -R
        sudo chown -R postgres:postgres \"$backup_pg_data_dir\"
    "
}

# --- Основной скрипт ---
main() {
    log "==================== СТАРТ УНИВЕРСАЛЬНОЙ СИНХРОНИЗАЦИИ ===================="
    
    # Чтение конфига
    main_ssh_host=$(parse_config main ssh_host)
    main_ssh_user=$(parse_config main ssh_user)
    main_ssh_pass=$(parse_config main ssh_pass)
    main_pg_user=$(parse_config main pg_user)
    main_pg_pass=$(parse_config main pg_pass)
    rep_user=$(parse_config main pg_replication_user)
    main_app_data_dir=$(parse_config main app_data_dir)
    main_pg_data_dir=$(parse_config main pg_data_dir)
    main_pg_conf_dir=$(parse_config main pg_conf_dir)

    backup_ssh_host=$(parse_config backup ssh_host)
    backup_ssh_user=$(parse_config backup ssh_user)
    backup_ssh_pass=$(parse_config backup ssh_pass)
    backup_app_data_dir=$(parse_config backup app_data_dir)
    backup_pg_data_dir=$(parse_config backup pg_data_dir)
    backup_pg_conf_dir=$(parse_config backup pg_conf_dir)
    backup_app_service=$(parse_config backup app_service)

    # Генерация пароля для репликатора
    rep_pass=$(openssl rand -base64 16)
    log "[ИНФО] Сгенерирован временный пароль для пользователя-репликатора $rep_user."

    # Подготовка
    ensure_deps "$main_ssh_host" "$main_ssh_user" "$main_ssh_pass"
    ensure_deps "$backup_ssh_host" "$backup_ssh_user" "$backup_ssh_pass"
    ensure_replication_user_and_hba "$main_ssh_host" "$main_ssh_user" "$main_ssh_pass" "$main_pg_conf_dir" "$main_pg_user" "$main_pg_pass" "$rep_user" "$rep_pass" "$backup_ssh_host"

    # Синхронизация
    manage_service "Остановка" "$backup_ssh_host" "$backup_ssh_user" "$backup_ssh_pass" "$backup_app_service"
    manage_postgres "Остановка" "$backup_ssh_host" "$backup_ssh_user" "$backup_ssh_pass"
    
    rsync_app_data "$main_ssh_host" "$main_ssh_user" "$main_ssh_pass" "$main_app_data_dir" "$backup_ssh_host" "$backup_ssh_user" "$backup_ssh_pass" "$backup_app_data_dir"
    run_pg_basebackup "$backup_ssh_host" "$backup_ssh_user" "$backup_ssh_pass" "$backup_pg_data_dir" "$rep_user" "$rep_pass" "$main_ssh_host"
    
    # Замена IP в конфигах на резервном
    log "[ШАГ] Замена IP-адресов в конфигурации PostgreSQL на резервном сервере..."
    local old_ip="$main_ssh_host"
    local new_ip="$backup_ssh_host"
    for conf_file in postgresql.conf pg_hba.conf; do
        local conf_path="$backup_pg_conf_dir/$conf_file"
        sshpass -p "$backup_ssh_pass" ssh -o StrictHostKeyChecking=no "$backup_ssh_user@$backup_ssh_host" "if [ -f '$conf_path' ]; then sudo sed -i 's/$old_ip/$new_ip/g' '$conf_path'; fi"
    done

    # Запуск
    manage_postgres "Запуск" "$backup_ssh_host" "$backup_ssh_user" "$backup_ssh_pass"
    # Тут можно добавить ожидание сокета
    manage_service "Запуск" "$backup_ssh_host" "$backup_ssh_user" "$backup_ssh_pass" "$backup_app_service"

    log "==================== СИНХРОНИЗАЦИЯ УСПЕШНО ЗАВЕРШЕНА ===================="
}

main "$@" 
