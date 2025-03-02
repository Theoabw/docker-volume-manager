#!/bin/bash
# dvmanager.sh
# A comprehensive script for managing Docker volume backups, restores, transfers,
# and remote restores using whiptail. This version includes improvements for:
# - Logging & verbosity
# - Error handling & pre-flight checks
# - Performance optimizations with parallel backups and progress indicators
# - Security validations and safer transfers
# - Backup naming, integrity verification, and retention policy
# - Modular, reusable functions
# - Command-line arguments and a help menu
# - Graceful exit on interruptions

#######################################
# Global Variables
#######################################
VERBOSE=1
RETENTION_DAYS=30  # Backups older than this (in days) will be deleted

# Store the original user's home directory
ORIGINAL_HOME=$(eval echo ~${SUDO_USER})
LOGFILE="/var/log/dvmanager.log"
BACKUP_DIR="$ORIGINAL_HOME/docker-volume-backups"

#######################################
# Check if the script is run as root.
# Re-runs with sudo if not run as root.
#######################################
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root. Re-running with sudo..."
        exec sudo bash "$0" "$@"
    fi
}

#######################################
# Log messages with timestamp.
# Globals:
#   LOGFILE, VERBOSE
# Arguments:
#   Message string
# Returns:
#   None
#######################################
log() {
    local message
    message="$(date +'%Y-%m-%d %H:%M:%S') - $1"
    echo "$message" >> "$LOGFILE"
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$message"
    fi
}

#######################################
# Prompt user for Y/n confirmation.
# Arguments:
#   Prompt message
# Returns:
#   0 if user selects Yes, 1 if No
#######################################
confirm_action() {
    local prompt=$1
    if whiptail --yesno "$prompt" 10 60; then
        return 0
    else
        return 1
    fi
}

#######################################
# Install missing dependencies.
# Dependencies: docker, rsync, whiptail, pv
# Installs missing dependencies using the appropriate package manager.
#######################################
install_dependencies() {
    local missing=0
    local install_cmd=""

    if command -v apt-get >/dev/null 2>&1; then
        install_cmd="sudo apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        install_cmd="sudo dnf install -y"
    elif command -v pacman >/dev/null 2>&1; then
        install_cmd="sudo pacman -S --noconfirm"
    else
        echo "Unsupported package manager. Please install the dependencies manually."
        exit 1
    fi

    for cmd in docker rsync whiptail pv; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Installing missing dependency: $cmd"
            $install_cmd "$cmd"
            if [ $? -ne 0 ]; then
                echo "Failed to install $cmd. Please install it manually."
                missing=1
            fi
        fi
    done

    if [ $missing -ne 0 ]; then
        echo "Some dependencies could not be installed. Please install them manually."
        exit 1
    fi
}

#######################################
# Check if required dependencies are installed.
# Dependencies: docker, rsync, whiptail, pv
# Exits if any dependency is missing.
#######################################
check_dependencies() {
    local missing=0
    for cmd in docker rsync whiptail pv; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Dependency missing: $cmd is not installed."
            missing=1
        fi
    done

    if [ $missing -ne 0 ]; then
        if confirm_action "Some dependencies are missing. Do you want to install them now?"; then
            echo "Installing missing dependencies..."
            install_dependencies
        else
            echo "Please install the missing dependencies before running this script."
            exit 1
        fi
    fi
}

#######################################
# Check and create necessary directories
# Ensures that backup and log directories exist
#######################################
check_directories() {
    if [ ! -d "$BACKUP_DIR" ]; then
        log "Creating backup directory at $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR" || { log "Failed to create backup directory! Exiting."; exit 1; }
    fi

    if [ ! -f "$LOGFILE" ]; then
        touch "$LOGFILE" || { echo "Failed to create log file! Exiting."; exit 1; }
    fi
}

#######################################
# Enhanced error handling function
# Arguments:
#   Exit code
#   Error message
# Returns:
#   None (exits script on failure)
#######################################
handle_error() {
    local exit_code=$1
    local message=$2
    if [ "$exit_code" -ne 0 ]; then
        log "ERROR: $message"
        whiptail --msgbox "ERROR: $message" 10 50
        exit "$exit_code"
    fi
}

#######################################
# Validate IP address format
# Arguments:
#   IP address string
# Returns:
#   0 if valid, 1 if invalid
#######################################
validate_ip() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $ip =~ $regex ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if ((octet < 0 || octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

#######################################
# Validate SSH connection
# Arguments:
#   username, IP address
# Returns:
#   0 if connection succeeds, 1 if it fails
#######################################
validate_ssh_connection() {
    local user=$1
    local ip=$2
    if ! ssh -o ConnectTimeout=5 "$user@$ip" "exit" 2>/dev/null; then
        whiptail --msgbox "Error: Unable to connect to $user@$ip via SSH. Check credentials or network." 10 50
        return 1
    fi
    return 0
}

#######################################
# Configurable backup retention policy
# Deletes backups older than RETENTION_DAYS days
#######################################
cleanup_old_backups() {
    log "Cleaning up backups older than $RETENTION_DAYS days..."
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$RETENTION_DAYS -exec rm -v {} \; >> "$LOGFILE" 2>&1
    log "Old backup cleanup completed."
}

#######################################
# Verify backup integrity
# Arguments:
#   Backup file path
# Returns:
#   0 if successful, 1 if corrupted
#######################################
verify_backup() {
    local backup_file=$1
    log "Verifying backup integrity: $backup_file"
    if tar -tzf "$backup_file" >/dev/null 2>&1; then
        log "Backup verified successfully: $backup_file"
        return 0
    else
        log "ERROR: Backup file corrupted: $backup_file"
        return 1
    fi
}

#######################################
# Helper: Select a Docker volume using whiptail menu
# Returns:
#   Selected volume name
#######################################
select_docker_volume() {
    local volumes
    volumes=$(docker volume ls --format "{{.Name}}")
    if [ -z "$volumes" ]; then
        whiptail --msgbox "No Docker volumes found." 8 40
        return 1
    fi

    local volume_menu=""
    for vol in $volumes; do
        volume_menu="$volume_menu $vol \"\""
    done

    local selected_volume
    selected_volume=$(whiptail --menu "Select a Docker volume:" 20 78 15 $volume_menu 3>&1 1>&2 2>&3)
    if [ -z "$selected_volume" ]; then
        whiptail --msgbox "No volume selected." 8 40
        return 1
    fi

    echo "$selected_volume"
    return 0
}

#######################################
# Helper: Select a backup file from BACKUP_DIR
# Returns:
#   Selected backup filename
#######################################
select_backup_file() {
    local backups
    backups=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    if [ -z "$backups" ]; then
        whiptail --msgbox "No backup files found in $BACKUP_DIR." 8 40
        return 1
    fi

    local backup_menu=""
    for file in $backups; do
        local fname
        fname=$(basename "$file")
        backup_menu="$backup_menu $fname \"\""
    done

    local selected_backup
    selected_backup=$(whiptail --menu "Select a backup file:" 20 78 15 $backup_menu 3>&1 1>&2 2>&3)
    if [ -z "$selected_backup" ]; then
        whiptail --msgbox "No backup selected." 8 40
        return 1
    fi

    echo "$selected_backup"
    return 0
}

#######################################
# Helper: Get user input with validation
# Arguments:
#   Prompt message
# Returns:
#   User input string
#######################################
get_user_input() {
    local prompt=$1
    local input
    input=$(whiptail --inputbox "$prompt" 8 40 3>&1 1>&2 2>&3)
    if [ -z "$input" ]; then
        whiptail --msgbox "Input cannot be empty." 8 40
        return 1
    fi
    echo "$input"
    return 0
}

#######################################
# Backup Docker volumes with parallelization,
# progress indicators, improved naming, cleanup, and integrity check.
#######################################
backup_volumes() {
    log "Starting backup process"
    check_directories
    cleanup_old_backups

    local volumes
    volumes=$(docker volume ls --format "{{.Name}}")
    if [ -z "$volumes" ]; then
        whiptail --msgbox "No Docker volumes found." 8 40
        return
    fi

    local checklist=""
    for vol in $volumes; do
        checklist="$checklist $vol \"\" OFF"
    done

    local selected
    selected=$(whiptail --checklist "Select volumes to backup:" 20 78 15 $checklist 3>&1 1>&2 2>&3)
    if [ -z "$selected" ]; then
        whiptail --msgbox "No volumes selected." 8 40
        return
    fi

    # Remove quotes from selection result
    selected=$(echo $selected | sed 's/"//g')

    for vol in $selected; do
        (
            local timestamp hostname backup_file
            timestamp=$(date +%Y%m%d%H%M%S)
            hostname=$(hostname)
            backup_file="${BACKUP_DIR}/${vol}-${hostname}-${timestamp}.tar.gz"
            log "Backing up volume: $vol to $backup_file"
            echo "Backing up: $vol..."

            # Use tar with progress (pv) and gzip compression
            local data_size
            data_size=$(docker run --rm -v "$vol":/data busybox du -sb /data | awk '{print $1}')
            docker run --rm -v "$vol":/data -v "$BACKUP_DIR":/backup busybox tar cf - -C /data . \
                | pv -s "$data_size" \
                | gzip > "$backup_file"

            if [ $? -eq 0 ]; then
                verify_backup "$backup_file"
            else
                log "ERROR: Backup failed for $vol"
            fi
        ) &
    done

    wait
    whiptail --msgbox "Backup process completed successfully!" 8 40
    log "Backup process completed"
}

#######################################
# Restore a backup to a Docker volume using a progress bar
#######################################
restore_backup() {
    log "Starting restore process"
    check_directories

    local selected_volume selected_backup size
    selected_volume=$(select_docker_volume)
    [ $? -ne 0 ] && return

    selected_backup=$(select_backup_file)
    [ $? -ne 0 ] && return

    if whiptail --yesno "Restore backup $selected_backup to volume $selected_volume? This will overwrite existing data!" 10 60; then
        log "Restoring $selected_backup to volume $selected_volume"
        size=$(gzip -l "$BACKUP_DIR/$selected_backup" | awk 'NR==2 {print $2}')
        docker run --rm -v "$selected_volume":/data -v "$BACKUP_DIR":/backup busybox sh -c "pv -s $size /backup/$selected_backup | tar xzf - -C /data" \
            && log "Restore successful for $selected_backup to volume $selected_volume" \
            || log "ERROR: Restore failed for $selected_backup to $selected_volume"
        whiptail --msgbox "Restore completed successfully!" 8 40
    else
        whiptail --msgbox "Restore cancelled." 8 40
    fi
}

#######################################
# Transfer a backup file to a remote machine using rsync
# with input validation and SSH connection check.
#######################################
transfer_backup() {
    log "Starting transfer process"
    check_directories

    local backups
    backups=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    if [ -z "$backups" ]; then
        whiptail --msgbox "No backup files found in $BACKUP_DIR." 8 40
        return
    fi

    local backup_menu selected_backup target_user target_ip
    backup_menu=""
    for file in $backups; do
        local fname
        fname=$(basename "$file")
        backup_menu="$backup_menu $fname \"\""
    done

    selected_backup=$(whiptail --menu "Select backup file to transfer:" 20 78 15 $backup_menu 3>&1 1>&2 2>&3)
    [ -z "$selected_backup" ] && { whiptail --msgbox "No backup selected." 8 40; return; }

    target_user=$(get_user_input "Enter target username:")
    [ $? -ne 0 ] && return
    target_ip=$(get_user_input "Enter target IP address:")
    [ $? -ne 0 ] && return

    if ! validate_ip "$target_ip"; then
        whiptail --msgbox "Invalid IP address: $target_ip" 8 40
        return
    fi

    if ! validate_ssh_connection "$target_user" "$target_ip"; then
        return
    fi

    if whiptail --yesno "Transfer $selected_backup to $target_user@$target_ip:~/docker-volume-backups/?" 8 40; then
        log "Transferring $selected_backup to $target_user@$target_ip"
        rsync -avz --progress "$BACKUP_DIR/$selected_backup" "$target_user@$target_ip:~/docker-volume-backups/" \
            && log "Transfer successful for $selected_backup" \
            || log "ERROR: Transfer failed for $selected_backup"
        whiptail --msgbox "Transfer completed!" 8 40
    else
        whiptail --msgbox "Transfer cancelled." 8 40
    fi
}

#######################################
# Restore a backup from a remote machine.
# Lists remote backups via SSH, then restores the selected one.
#######################################
remote_restore() {
    log "Starting remote restore process"
    local remote_user remote_ip remote_backups remote_menu selected_remote_backup selected_volume
    remote_user=$(get_user_input "Enter remote username:")
    [ $? -ne 0 ] && return
    remote_ip=$(get_user_input "Enter remote IP address:")
    [ $? -ne 0 ] && return

    if ! validate_ip "$remote_ip"; then
        whiptail --msgbox "Invalid IP address: $remote_ip" 8 40
        return
    fi

    if ! validate_ssh_connection "$remote_user" "$remote_ip"; then
        return
    fi

    remote_backups=$(ssh "$remote_user@$remote_ip" 'ls ~/docker-volume-backups/*.tar.gz 2>/dev/null')
    if [ -z "$remote_backups" ]; then
        whiptail --msgbox "No backup files found on remote machine." 8 40
        return
    fi

    remote_menu=""
    for file in $remote_backups; do
        local fname
        fname=$(basename "$file")
        remote_menu="$remote_menu $fname \"\""
    done

    selected_remote_backup=$(whiptail --menu "Select remote backup file:" 20 78 15 $remote_menu 3>&1 1>&2 2>&3)
    [ -z "$selected_remote_backup" ] && { whiptail --msgbox "No remote backup selected." 8 40; return; }

    selected_volume=$(select_docker_volume)
    [ $? -ne 0 ] && return

    if whiptail --yesno "Restore remote backup $selected_remote_backup to local volume $selected_volume?" 8 40; then
        log "Transferring remote backup $selected_remote_backup from $remote_user@$remote_ip to local"
        rsync -avz "$remote_user@$remote_ip:~/docker-volume-backups/$selected_remote_backup" "$BACKUP_DIR/"
        if [ $? -ne 0 ]; then
            whiptail --msgbox "Error transferring remote backup." 8 40
            log "Error transferring remote backup $selected_remote_backup"
            return
        fi
        log "Transfer complete. Restoring backup to volume $selected_volume"
        docker run --rm -v "$selected_volume":/data -v "$BACKUP_DIR":/backup busybox tar xzf /backup/"$selected_remote_backup" -C /data
        if [ $? -ne 0 ]; then
            whiptail --msgbox "Error restoring remote backup." 8 40
            log "Error restoring remote backup $selected_remote_backup to volume $selected_volume"
            return
        fi
        whiptail --msgbox "Remote restore completed." 8 40
        log "Remote restore completed for $selected_remote_backup to volume $selected_volume"
    else
        whiptail --msgbox "Remote restore cancelled." 8 40
    fi
}

#######################################
# Main Menu loop: Displays options via whiptail.
#######################################
main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Docker Volume Manager" --menu "Choose an option:" 20 78 10 \
            "1" "Backup Docker Volumes" \
            "2" "Restore a Backup" \
            "3" "Transfer Backup to Another Machine" \
            "4" "Restore from Remote Backup" \
            "5" "Exit" 3>&1 1>&2 2>&3)
        case $choice in
            "1") backup_volumes ;;
            "2") restore_backup ;;
            "3") transfer_backup ;;
            "4") remote_restore ;;
            "5") break ;;
            *) whiptail --msgbox "Invalid option." 8 40 ;;
        esac
    done
}

#######################################
# Display Help Menu
#######################################
display_help() {
    echo "Docker Volume Manager - dvmanager.sh"
    echo ""
    echo "Usage: sudo ./dvmanager.sh [OPTION]"
    echo ""
    echo "Options:"
    echo "  --help            Show this help message"
    echo "  --backup          Run backup interactively"
    echo "  --restore         Restore a backup interactively"
    echo "  --transfer        Transfer a backup to another machine"
    echo "  --remote-restore  Restore a backup from a remote machine"
    echo "  --verbose         Enable verbose output"
    echo ""
    echo "Without arguments, the script runs in interactive menu mode."
    exit 0
}

#######################################
# Parse command-line arguments
#######################################
for arg in "$@"; do
    case $arg in
        --help)
            display_help
            ;;
        --backup)
            backup_volumes
            exit 0
            ;;
        --restore)
            restore_backup
            exit 0
            ;;
        --transfer)
            transfer_backup
            exit 0
            ;;
        --remote-restore)
            remote_restore
            exit 0
            ;;
        --verbose)
            VERBOSE=1
            ;;
        *)
            echo "Unknown option: $arg"
            display_help
            ;;
    esac
done

#######################################
# Graceful exit on Ctrl+C
#######################################
trap ctrl_c INT
ctrl_c() {
    echo ""
    log "Script interrupted by user."
    whiptail --msgbox "Operation cancelled by user." 8 40
    exit 1
}

#######################################
# Start-up checks and main menu launch (if no arguments provided)
#######################################
check_sudo "$@"
check_dependencies
check_directories

if [ "$#" -eq 0 ]; then
    main_menu
fi
