# Universal PostgreSQL & Application Data Synchronization Tool / Универсальная утилита для синхронизации данных PostgreSQL и приложений
---

A script for "hot" synchronization of application data and a PostgreSQL database cluster from a primary to a backup server. It uses `rsync` for application files and `pg_basebackup` for a consistent, live backup of the PostgreSQL cluster.

This is a **universal** version: all parameters, including PostgreSQL credentials, are set explicitly in the configuration file, making it adaptable to any application or environment.

---

Скрипт для «горячей» синхронизации данных приложения и кластера базы данных PostgreSQL с основного сервера на резервный. Использует `rsync` для файлов приложения и `pg_basebackup` для создания консистентной резервной копии работающего кластера PostgreSQL.

Это **универсальная** версия: все параметры, включая данные для подключения к PostgreSQL, задаются в файле конфигурации, что делает его адаптируемым к любому приложению и окружению.

---

## ⚠️ Requirements / Требования

Before using this script, ensure the following packages are installed on **both** the primary and backup servers. The script will attempt to install them automatically if missing.

Перед использованием скрипта убедитесь, что в вашей системе на **обоих** серверах (основном и резервном) установлены следующие пакеты. Скрипт попытается установить их автоматически, если они отсутствуют.

**Required packages / Необходимые пакеты:**
- `rsync`
- `sshpass` (used for password-based SSH authentication)
- `postgresql-client` (provides `psql` and `pg_basebackup`)
- `openssl` (for generating a temporary password)

### ❗ Important / Важно
- The script requires **passwordless `sudo`** for the SSH user to manage services (`systemctl`), edit configuration files, and set directory permissions.
- Скрипту требуется **беспарольный `sudo`** для SSH-пользователя, чтобы управлять службами (`systemctl`), редактировать файлы конфигурации и устанавливать права на каталоги.

---

## 🇬🇧 Installation and Usage (English)

1.  **Place the script and config file in the same directory:**
    - `sync_universal.sh`
    - `sync_universal.conf`

2.  **Make the script executable:**
    ```bash
    chmod +x sync_universal.sh
    ```

3.  **Edit the configuration file `sync_universal.conf`** with your server and application details (see configuration section below).

4.  **Run the script:**
    ```bash
    ./sync_universal.sh
    ```
    All actions and potential errors will be logged to `sync_universal.log`.

---

## 🇷🇺 Установка и использование (Russian)

1.  **Поместите скрипт и файл конфигурации в одну директорию:**
    - `sync_universal.sh`
    - `sync_universal.conf`

2.  **Сделайте скрипт исполняемым:**
    ```bash
    chmod +x sync_universal.sh
    ```
3.  **Отредактируйте файл конфигурации `sync_universal.conf`**, указав данные ваших серверов и приложений (см. раздел о конфигурации ниже).

4.  **Запустите скрипт:**
    ```bash
    ./sync_universal.sh
    ```
    Все действия и возможные ошибки будут записаны в лог-файл `sync_universal.log`.

---

## ⚙️ Configuration / Настройка (`sync_universal.conf`)

The script is controlled by the `sync_universal.conf` file.

Поведение скрипта управляется файлом `sync_universal.conf`.

### `[main]` - Primary Server / Основной сервер
-   `ssh_host`, `ssh_user`, `ssh_pass`: Connection details for the primary server. / Данные для подключения к основному серверу.
-   `pg_user`: An administrative PostgreSQL user (like `postgres`) that has rights to create other users. / Административный пользователь PostgreSQL (например, `postgres`), обладающий правами на создание других пользователей.
-   `pg_pass`: The password for the `pg_user`. / Пароль для `pg_user`.
-   `pg_replication_user`: A name for the PostgreSQL replication user that the script will create and manage automatically (e.g., `replicator`). / Имя для пользователя репликации PostgreSQL, которого скрипт создаст и настроит автоматически.
-   `app_data_dir`: Absolute path to the application's data directory. / Абсолютный путь к каталогу данных приложения.
-   `pg_data_dir`: Absolute path to the PostgreSQL data directory (e.g., `/var/lib/postgresql/17/main`). / Абсолютный путь к каталогу данных PostgreSQL.
-   `pg_conf_dir`: Absolute path to the PostgreSQL configuration directory (e.g., `/etc/postgresql/17/main`). / Абсолютный путь к каталогу конфигурации PostgreSQL.
-   `app_service`: The name of the `systemd` service for your application (e.g., `my-app.service`). This service is NOT stopped on the primary server during sync. / Имя `systemd`-сервиса вашего приложения. Этот сервис НЕ останавливается на основном сервере во время синхронизации.

### `[backup]` - Backup Server / Резервный сервер
-   `ssh_host`, `ssh_user`, `ssh_pass`: Connection details for the backup server. / Данные для подключения к резервному серверу.
-   `app_data_dir`, `pg_data_dir`, `pg_conf_dir`: Corresponding paths on the backup server where data will be synced. / Соответствующие пути на резервном сервере, куда будут синхронизированы данные.
-   `app_service`: The name of the application's `systemd` service on the backup server, which will be stopped before sync and started after. / Имя `systemd`-сервиса приложения на резервном сервере, который будет остановлен перед синхронизацией и запущен после. 
