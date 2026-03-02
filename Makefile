ENV_FILE ?= .env
include $(ENV_FILE)

SHELL := /bin/bash

# Allow: make restore RESTORE_PATHS="Documents/ .config/Code/User/"
RESTORE_PATHS ?=

# Passkey check: resolves passphrase mode and sets shell vars _pv and _paranoid.
# _pv     : --volume flag for the passkey file (empty in paranoid mode)
# _paranoid: PARANOID_MODE value to pass into the container
# Usage: $(call _passkey_check,/container/path/to/passfile)
define _passkey_check
if [ "${PARANOID_MODE}" = "true" ]; then \
	_pv=""; _paranoid="true"; \
else \
	if [ -d "${GOCRYPTFS_PASSKEY_FILE}" ]; then \
		echo "Removing stale directory '${GOCRYPTFS_PASSKEY_FILE}' (Docker artifact)..."; \
		rmdir "${GOCRYPTFS_PASSKEY_FILE}" || { echo "Error: '${GOCRYPTFS_PASSKEY_FILE}' is a non-empty directory."; exit 1; }; \
	fi; \
	if [ ! -f "${GOCRYPTFS_PASSKEY_FILE}" ]; then \
		echo "Passkey file '${GOCRYPTFS_PASSKEY_FILE}' not found."; \
		read -r -p "Enter passphrase interactively without saving to disk? [y/N] " _choice; \
		if [ "$$_choice" = "y" ] || [ "$$_choice" = "Y" ]; then \
			echo "Switching to interactive passphrase for this run."; \
			_pv=""; _paranoid="true"; \
		else \
			read -r -p "Enter a passphrase to create it: " passphrase; \
			printf '%s' "$$passphrase" > "${GOCRYPTFS_PASSKEY_FILE}"; \
			echo "Passkey file created at ${GOCRYPTFS_PASSKEY_FILE}"; \
			chmod 600 "${GOCRYPTFS_PASSKEY_FILE}"; \
			_pv="--volume ${GOCRYPTFS_PASSKEY_FILE}:$(1)"; _paranoid="false"; \
		fi; \
	else \
		chmod 600 "${GOCRYPTFS_PASSKEY_FILE}"; \
		_pv="--volume ${GOCRYPTFS_PASSKEY_FILE}:$(1)"; _paranoid="false"; \
	fi; \
fi
endef

.PHONY: build backup backup_as_root \
        restore restore_to_origin restore_as_root restore_as_root_to_origin \
        view view_as_root \
        run_container run_container_as_root check-passkey clean

all: build run_container

# build and backup
bb: build backup

# build and root backup
bbr: build backup_as_root

# build and root restore (staging)
brr: build restore_as_root

# restore shorthands
r:   restore
ro:  restore_to_origin
rr:  restore_as_root
rro: restore_as_root_to_origin
v:   view
vr:  view_as_root

build:
	@echo "Building Docker image..."
	@docker build . \
		--build-arg ALPINE_VERSION=${ALPINE_VERSION} \
		--build-arg GOCRYPTFS_VERSION=${GOCRYPTFS_VERSION} \
		--tag ${DOCKER_IMAGE_TAG_NAME} \
		--tag ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION}

# WARNING: permanently deletes the passkey, gocryptfs config files, and Docker image.
# Make sure the master key is backed up before running this.
clean:
	@echo "WARNING: this will permanently delete the passkey file, gocryptfs config files, and Docker image."
	@echo "If you lose the passkey without a master key backup, the encrypted backup becomes unrecoverable."
	@read -r -p "Type YES to continue: " confirm && [ "$$confirm" = "YES" ] || { echo "Aborted."; exit 1; }
	@if docker inspect --type container gocryptfs > /dev/null 2>&1; then docker rm -f gocryptfs; fi
	@if docker inspect --type image ${DOCKER_IMAGE_TAG_NAME} > /dev/null 2>&1; then \
		docker rmi ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} ${DOCKER_IMAGE_TAG_NAME}; \
	fi
	@rm -f ${GOCRYPTFS_PASSKEY_FILE}
	@rm -f ${BACKUP_SOURCE_FOLDER}/.gocryptfs.reverse.conf \
	       ${BACKUP_SOURCE_FOLDER}/.gocryptfs.reverse.conf.original \
	       ${BACKUP_ENCRYPTION_CONF}
	@echo "Done."

# Standalone passkey setup utility (useful for verifying or pre-creating the passkey file).
check-passkey:
	@if [ "${PARANOID_MODE}" = "true" ]; then \
		echo "PARANOID_MODE is enabled: passphrase will be entered interactively. No passkey file needed."; \
	else \
		if [ -d "${GOCRYPTFS_PASSKEY_FILE}" ]; then \
			echo "Removing stale directory '${GOCRYPTFS_PASSKEY_FILE}' (Docker artifact)..."; \
			rmdir "${GOCRYPTFS_PASSKEY_FILE}" || { echo "Error: '${GOCRYPTFS_PASSKEY_FILE}' is a non-empty directory."; exit 1; }; \
		fi; \
		if [ ! -f "${GOCRYPTFS_PASSKEY_FILE}" ]; then \
			echo "Passkey file '${GOCRYPTFS_PASSKEY_FILE}' not found."; \
			read -r -p "Enter a passphrase to create it: " passphrase && \
			printf '%s' "$$passphrase" > "${GOCRYPTFS_PASSKEY_FILE}" && \
			echo "Passkey file created at ${GOCRYPTFS_PASSKEY_FILE}"; \
		fi; \
		if [ -f "${GOCRYPTFS_PASSKEY_FILE}" ]; then \
			chmod 600 "${GOCRYPTFS_PASSKEY_FILE}"; \
		else \
			echo "Error: passkey file '${GOCRYPTFS_PASSKEY_FILE}' could not be created."; \
			exit 1; \
		fi; \
	fi

backup:
	@$(call _passkey_check,/backup/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--security-opt label=disable \
		--entrypoint /bin/bash \
		--volume ${BACKUP_SOURCE_FOLDER}:/backup/src \
		--volume ${BACKUP_FILTER_RULES}:/backup/brave-filter-rules.txt \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/backup.sh \
			"/backup/src" \
			"/backup/enc" \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/backup/passfile" \
			${REMOTE_SERVER} \
			"/backup/brave-filter-rules.txt" \
			${RSYNC_RATE_LIMIT} \
			${RSYNC_LOOP} \
			${GOCRYPTFS_CIPHER} \
			${GOCRYPTFS_SCRYPT_N} \
			${GOCRYPTFS_ENCRYPT_NAMES}

backup_as_root:
	@$(call _passkey_check,/backup/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--entrypoint /bin/bash \
		--volume /etc:/backup/src/etc \
		--volume /home:/backup/src/home \
		--volume /opt:/backup/src/opt \
		--volume /root:/backup/src/root \
		--volume /srv:/backup/src/srv \
		--volume ${BACKUP_FILTER_RULES}:/backup/brave-filter-rules.txt \
		--volume ${BACKUP_ENCRYPTION_CONF}:/backup/src/.gocryptfs.reverse.conf.original \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/backup.sh \
			"/backup/src" \
			"/backup/enc" \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/backup/passfile" \
			${REMOTE_SERVER} \
			"/backup/brave-filter-rules.txt" \
			${RSYNC_RATE_LIMIT} \
			${RSYNC_LOOP} \
			${GOCRYPTFS_CIPHER} \
			${GOCRYPTFS_SCRYPT_N} \
			${GOCRYPTFS_ENCRYPT_NAMES}

# Restore user backup to a staging directory (safe — review before moving)
restore:
	@$(call _passkey_check,/restore/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--entrypoint /bin/bash \
		--volume ${RESTORE_DESTINATION}:/restore/origin \
		--volume ${RESTORE_PATHS_FILE}:/restore/restore-paths.txt \
		--volume ${RESTORE_EXCLUDE_LIST}:/restore/restore-exclude-list.txt \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env RESTORE_PATHS='${RESTORE_PATHS}' \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/restore.sh \
			${REMOTE_SERVER} \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/restore/enc" \
			"/restore/dec" \
			"/restore/passfile" \
			"/restore/restore-exclude-list.txt" \
			${RSYNC_RATE_LIMIT} \
			${RSYNC_LOOP} \
			"/restore/origin" \
			"/restore/restore-paths.txt"

# Restore user backup directly to original home directory
restore_to_origin:
	@$(call _passkey_check,/restore/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--entrypoint /bin/bash \
		--volume ${BACKUP_SOURCE_FOLDER}:/restore/origin \
		--volume ${RESTORE_PATHS_FILE}:/restore/restore-paths.txt \
		--volume ${RESTORE_EXCLUDE_LIST}:/restore/restore-exclude-list.txt \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env RESTORE_PATHS='${RESTORE_PATHS}' \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/restore.sh \
			${REMOTE_SERVER} \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/restore/enc" \
			"/restore/dec" \
			"/restore/passfile" \
			"/restore/restore-exclude-list.txt" \
			${RSYNC_RATE_LIMIT} \
			${RSYNC_LOOP} \
			"/restore/origin" \
			"/restore/restore-paths.txt"

# Restore root backup to a staging directory (safe — review before moving)
restore_as_root:
	@$(call _passkey_check,/restore/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--entrypoint /bin/bash \
		--volume ${RESTORE_DESTINATION}:/restore/origin \
		--volume ${RESTORE_PATHS_FILE}:/restore/restore-paths.txt \
		--volume ${RESTORE_EXCLUDE_LIST}:/restore/restore-exclude-list.txt \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env RESTORE_PATHS='${RESTORE_PATHS}' \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/restore.sh \
			${REMOTE_SERVER} \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/restore/enc" \
			"/restore/dec" \
			"/restore/passfile" \
			"/restore/restore-exclude-list.txt" \
			${RSYNC_RATE_LIMIT} \
			${RSYNC_LOOP} \
			"/restore/origin" \
			"/restore/restore-paths.txt"

# Restore root backup directly to original system paths (/etc, /home, /opt, /root, /srv)
restore_as_root_to_origin:
	@$(call _passkey_check,/restore/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--entrypoint /bin/bash \
		--volume /etc:/restore/origin/etc \
		--volume /home:/restore/origin/home \
		--volume /opt:/restore/origin/opt \
		--volume /root:/restore/origin/root \
		--volume /srv:/restore/origin/srv \
		--volume ${RESTORE_PATHS_FILE}:/restore/restore-paths.txt \
		--volume ${RESTORE_EXCLUDE_LIST}:/restore/restore-exclude-list.txt \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env RESTORE_PATHS='${RESTORE_PATHS}' \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/restore.sh \
			${REMOTE_SERVER} \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/restore/enc" \
			"/restore/dec" \
			"/restore/passfile" \
			"/restore/restore-exclude-list.txt" \
			${RSYNC_RATE_LIMIT} \
			${RSYNC_LOOP} \
			"/restore/origin" \
			"/restore/restore-paths.txt"

# Serves the decrypted backup read-only over SFTP on host port 2222 (user backup).
# Connect your file manager to: sftp://root@localhost:2222/gocrypt-view/decrypted
view:
	@$(call _passkey_check,/gocrypt-view/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--security-opt label=disable \
		--entrypoint /bin/bash \
		--publish 127.0.0.1:2222:22 \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/view.sh \
			${REMOTE_SERVER} \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/gocrypt-view/passfile" \
			"/gocrypt-view/encrypted" \
			"/gocrypt-view/decrypted"

# Serves the decrypted backup read-only over SFTP on host port 2222 (root backup).
# Connect your file manager to: sftp://root@localhost:2222/gocrypt-view/decrypted
view_as_root:
	@$(call _passkey_check,/gocrypt-view/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--security-opt label=disable \
		--entrypoint /bin/bash \
		--publish 127.0.0.1:2222:22 \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		--volume ${SSH_KNOWN_HOSTS_FILE}:/root/.ssh/known_hosts \
		$$_pv \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION} \
		/app/view.sh \
			${REMOTE_SERVER} \
			${REMOTE_SERVER_BACKUP_FOLDER} \
			"/gocrypt-view/passfile" \
			"/gocrypt-view/encrypted" \
			"/gocrypt-view/decrypted"

run_container:
	@$(call _passkey_check,/backup/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--security-opt label=disable \
		--entrypoint /bin/bash \
		--volume ${BACKUP_SOURCE_FOLDER}:/backup/src \
		--volume ${BACKUP_FILTER_RULES}:/backup/brave-filter-rules.txt \
		--volume ${SSH_KEY_FILE}:/home/crypt/.ssh/id_rsa \
		$$_pv \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION}

run_container_as_root:
	@$(call _passkey_check,/backup/passfile); \
	docker run \
		--name gocryptfs \
		--user root \
		--cap-add SYS_ADMIN \
		--device /dev/fuse \
		--security-opt apparmor:unconfined \
		--security-opt label=disable \
		--entrypoint /bin/bash \
		--volume /etc:/backup/src/etc \
		--volume /home:/backup/src/home \
		--volume /opt:/backup/src/opt \
		--volume /root:/backup/src/root \
		--volume /srv:/backup/src/srv \
		--volume ${BACKUP_FILTER_RULES}:/backup/brave-filter-rules.txt \
		--volume ${BACKUP_ENCRYPTION_CONF}:/backup/src/.gocryptfs.reverse.conf.original \
		--volume ${SSH_KEY_FILE}:/root/.ssh/id_rsa \
		$$_pv \
		--env PARANOID_MODE=$$_paranoid \
		--rm \
		--interactive --tty ${DOCKER_IMAGE_TAG_NAME}:${DOCKER_IMAGE_TAG_VERSION}
