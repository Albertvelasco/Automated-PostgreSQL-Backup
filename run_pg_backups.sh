

#!/bin/bash
set -e
set -o pipefail

# ============================================
# Step 1 – Configuration
# ============================================
HOST_USER="$(whoami)"
HOST_NAME="$(hostname)"
DATESTAMP="$(date +%F-%H%M%S)"
BASE_DIR="/home/velasco-albert/Laboratory Exercises/Lab8"
BACKUP_DIR="/var/backups/postgres"
LOG_FILE="/var/log/pg_backup.log"
DB_NAME="production_db"
PG_USER="postgres"
PG_HOST="localhost"
EMAIL_SUCCESS_TO="dba-alerts@yourcompany.com"
EMAIL_FAILURE_TO="dba-alerts@yourcompany.com"
RCLONE_REMOTE="gdrive_backups:"
RETENTION_DAYS=7

mkdir -p "${BACKUP_DIR}"

if [ ! -f "${LOG_FILE}" ]; then
  sudo touch "${LOG_FILE}"
  sudo chown "${HOST_USER}" "${LOG_FILE}" || true
fi



# ============================================
# Step 2 – Functions
# ============================================
log_message() {
  echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"
}

# ============================================
# Step 3 – Logical Backup
# ============================================
BACKUP_FAILED=0
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${DATESTAMP}.dump"

log_message "=== Starting Full Logical Backup for ${DB_NAME} ==="
log_message "Backup file: ${BACKUP_FILE}"

if sudo -u "${PG_USER}" pg_dump -h "${PG_HOST}" -Fc -f "${BACKUP_FILE}" "${DB_NAME}" >> "${LOG_FILE}" 2>&1; then
  log_message "Logical backup completed successfully."
else
  BACKUP_FAILED=1
  log_message "ERROR: Logical backup failed for ${DB_NAME}!"
fi

if [ "${BACKUP_FAILED}" -eq 0 ]; then
  log_message "Task 1 complete — Logical backup success."
else
  log_message "Task 1 failed — Check ${LOG_FILE} for details."
fi


# ============================================
# Step 3 – Physical Base Backup
# ============================================

PHYSICAL_FILE="${BACKUP_DIR}/pg_base_backup_${DATESTAMP}.tar.gz"
log_message "Starting physical base backup: ${PHYSICAL_FILE}"

# Create temporary directory for backup
TEMP_DIR="/tmp/pg_basebackup_${DATESTAMP}"
sudo -u "${PG_USER}" mkdir -p "${TEMP_DIR}"

# Run base backup as postgres user
if sudo -u "${PG_USER}" pg_basebackup -h "${PG_HOST}" -D "${TEMP_DIR}" -Ft -z -X stream >> "${LOG_FILE}" 2>&1; then
  # Compress and move to backup directory
  sudo tar -czf "${PHYSICAL_FILE}" -C "${TEMP_DIR}" .
  sudo rm -rf "${TEMP_DIR}"
  log_message "Physical base backup successful."
else
  log_message "ERROR: Physical base backup failed!"
  sudo rm -rf "${TEMP_DIR}"
  exit 1
fi

# ============================================
# Step 4 – Email Notification
# ============================================

EMAIL_TO="velasco.albert2030@gmail.com"
EMAIL_SUBJECT="PostgreSQL Backup Report - ${DATESTAMP}"

# Prepare the message body
EMAIL_BODY=$(cat <<EOF
PostgreSQL Backup Completed

Date: ${DATESTAMP}
Host: ${PG_HOST}
Database: ${PG_DB}
Backup Directory: ${BACKUP_DIR}

Status:
- Logical Backup: SUCCESS
- Physical Backup: SUCCESS

See detailed log in: ${LOG_FILE}
EOF
)

# Send email using msmtp
echo "${EMAIL_BODY}" | msmtp -a gmail -t <<EOF
To: ${EMAIL_TO}
Subject: ${EMAIL_SUBJECT}
From: PostgreSQL Backup <${EMAIL_TO}>

${EMAIL_BODY}
EOF

log_message "Email notification sent to ${EMAIL_TO}"


# ============================================
# Step 5 – Cloud Upload (Google Drive)
# ============================================

if [ "${BACKUP_FAILED}" -eq 0 ]; then
  log_message "Uploading backups to Google Drive..."

  if rclone copy "${BACKUP_DIR}" "${RCLONE_REMOTE}" --log-file="${LOG_FILE}" --log-level=INFO; then
    log_message "Upload completed successfully."

    # Send success email
    echo -e "Subject: ✅ SUCCESS: PostgreSQL Backup and Upload\n\nSuccessfully created and uploaded:\n- ${BACKUP_FILE}\n- ${BACKUP_DIR}/pg_base_backup_${DATESTAMP}.tar.gz" \
      | msmtp -a gmail "${EMAIL_SUCCESS_TO}"

    # Local Cleanup – delete files older than 7 days
    log_message "Cleaning up old backups older than ${RETENTION_DAYS} days..."
    find "${BACKUP_DIR}" -type f -mtime +${RETENTION_DAYS} -exec rm -f {} \;
    log_message "Old backup files deleted."

  else
    log_message "ERROR: Upload to Google Drive failed!"
    echo -e "Subject: ❌ FAILURE: PostgreSQL Backup Upload\n\nBackups were created locally but failed to upload to Google Drive.\nCheck rclone logs for details." \
      | msmtp -a gmail "${EMAIL_FAILURE_TO}"
  fi

else
  log_message "Skipping upload — backup failed."
fi



# ============================================
# Step 6 – Local Cleanup (Automated Retention)
# ============================================

if [ "${BACKUP_FAILED}" -eq 0 ]; then
  log_message "Starting cleanup: Deleting backups older than ${RETENTION_DAYS} days from ${BACKUP_DIR}..."
  
  find "${BACKUP_DIR}" -type f -mtime +${RETENTION_DAYS} -exec rm -f {} \;
  
  log_message "Cleanup complete — Old backups older than ${RETENTION_DAYS} days deleted."
else
  log_message "Skipping cleanup — Backup or upload failed."
fi
