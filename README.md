
# Docker Volume Manager - dvmanager.sh

`dvmanager.sh` is a bash script for managing Docker volume backups, restores, transfers, and remote restores. The script is designed to simplify the process of Docker volume management while providing features like progress bars, backup verification, parallel backups, and more.

### Features:
- **Backup Docker Volumes**: Select and back up Docker volumes with the option to select multiple volumes.
- **Restore Docker Volumes**: Restore Docker volumes from locally stored backups.
- **Transfer Backup**: Transfer backup files to a remote machine using `rsync`.
- **Restore from Remote Backup**: Restore Docker volumes from backups stored on a remote machine.
- **Parallel Backups**: Perform multiple volume backups simultaneously.
- **Progress Indicators**: Shows progress bars while backing up or restoring.
- **Automatic Backup Cleanup**: Automatically delete backups older than a specified retention period.
- **Backup Integrity**: Verify the integrity of backup files.
- **Command-Line Arguments**: Run the script in automated or non-interactive mode using command-line options.
- **Graceful Exit**: Handles user interruptions (`Ctrl+C`) gracefully.
  
## Requirements:
- Docker
- Rsync
- Whiptail
- PV (Pipe Viewer)

## Installation:

1. Clone this repository:
    ```bash
    git clone https://github.com/yourusername/docker-volume-manager.git
    ```

2. Ensure the script is executable:
    ```bash
    chmod +x dvmanager.sh
    ```

- **Optional**: You can also download the script directly using `curl`:

    ```bash
    curl -L https://github.com/Theoabw/docker-volume-manager/raw/main/dvmanager.sh -o /tmp/dvmanager.sh && sudo bash /tmp/dvmanager.sh
    ```

## Usage:

### Interactive Mode:
If no arguments are provided, the script will run in interactive menu mode using `whiptail` to guide you through the process:

```bash
sudo ./dvmanager.sh
```

### Command-Line Options:
You can also specify options to run specific actions directly:

```bash
# Backup volumes
sudo ./dvmanager.sh --backup

# Restore from a local backup
sudo ./dvmanager.sh --restore

# Transfer a backup to a remote machine
sudo ./dvmanager.sh --transfer

# Restore from a remote backup
sudo ./dvmanager.sh --remote-restore

# Enable verbose output for detailed logs
sudo ./dvmanager.sh --verbose
```

### Help Menu:
To view the help menu with usage instructions, run:
```bash
sudo ./dvmanager.sh --help
```

## Configuration:
- **Retention Days**: You can configure the retention period for backups by editing the `RETENTION_DAYS` variable in the script.
  
## Security:
- The script validates user inputs for IP addresses and SSH connections to ensure safe transfers.
  
## License:
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

