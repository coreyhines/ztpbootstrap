#!/usr/bin/env python3
"""
Configuration Manager with Thread-Safe File Locking
Addresses COMPREHENSIVE_AUDIT_REPORT.md Issue #1 (Race Condition in Config File Updates)
"""

import errno
import fcntl
import os
import shutil
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, Optional

import yaml

# config.yaml and its backups live in the nginx docroot and hold secrets
# (enrollment tokens, auth hashes), so they are only readable by the owner (#67).
CONFIG_FILE_MODE = 0o600

# How often a lock waiter re-tries a non-blocking flock while it waits.
_LOCK_POLL_INTERVAL = 0.05

Validator = Callable[[Dict], tuple[bool, Optional[str]]]


def create_unique_backup(
    source: Path, directory: Path, prefix: str, suffix: str = "", mode: int = CONFIG_FILE_MODE
) -> Path:
    """
    Copy ``source`` to a new, never-before-used backup file and return its path.

    Names are ``<prefix><seconds>_<microseconds><suffix>``. If that name is taken
    (two backups in the same microsecond, or a clock step back), a ``_<n>``
    collision suffix is appended. The file is created with O_EXCL, so concurrent
    writers can never clobber each other's backups (#58). The backup is created
    with ``mode`` (0600 by default) because it holds the same secrets as the
    source (#67). Its mtime is the time of the backup, not of the source, so
    mtime-ordered cleanup keeps the newest backups.
    """
    now_ns = time.time_ns()
    stamp = f"{now_ns // 1_000_000_000}_{(now_ns // 1000) % 1_000_000:06d}"
    directory = Path(directory)

    attempt = 0
    while True:
        extra = f"_{attempt}" if attempt else ""
        backup_path = directory / f"{prefix}{stamp}{extra}{suffix}"
        try:
            fd = os.open(backup_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        except FileExistsError:
            attempt += 1
            continue
        break

    try:
        os.fchmod(fd, mode)  # O_CREAT mode is filtered by the umask
        with os.fdopen(fd, "wb") as dst, open(source, "rb") as src:
            shutil.copyfileobj(src, dst)
    except BaseException:
        try:
            backup_path.unlink()
        except OSError:
            pass
        raise
    return backup_path


class ConfigManager:
    """
    Thread-safe configuration file manager with file locking.

    This class provides atomic read-modify-write operations for config.yaml,
    preventing race conditions when multiple endpoints try to update different
    sections of the configuration simultaneously.

    Features:
    - Thread-safe operations using threading.Lock
    - Cross-process locking using fcntl.flock on a sidecar lock file
      (``<config>.lock``), held across the whole read-modify-write (#18)
    - Atomic writes: temp file in the same directory, fsync, os.replace (#17)
    - Lock timeouts that raise TimeoutError (#48)
    - Unique, 0600 backups created before every write (#58, #67)
    - Validation support
    """

    def __init__(self, config_path: Path, max_backups: int = 10):
        """
        Initialize ConfigManager.

        Args:
            config_path: Path to config.yaml file
            max_backups: Maximum number of backup files to keep
        """
        self.config_path = Path(config_path)
        self.lock_path = self.config_path.with_name(self.config_path.name + ".lock")
        self._lock = threading.Lock()
        self.max_backups = max_backups

    # ------------------------------------------------------------------ locking

    @contextmanager
    def _locked(self, exclusive: bool, timeout: Optional[float]) -> Iterator[None]:
        """
        Hold the thread lock and a flock on the sidecar lock file.

        ``timeout`` bounds the total wait for both locks; ``None`` waits forever.

        Raises:
            TimeoutError: If the locks cannot be acquired within ``timeout``
        """
        deadline = None if timeout is None else time.monotonic() + max(timeout, 0)

        if not self._lock.acquire(timeout=-1 if timeout is None else max(timeout, 0)):
            raise TimeoutError(f"Timed out waiting for config lock on {self.config_path}")
        try:
            fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, CONFIG_FILE_MODE)
            try:
                op = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
                while True:
                    try:
                        fcntl.flock(fd, op | fcntl.LOCK_NB)
                        break
                    except OSError as e:
                        if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                            raise
                    if deadline is not None and time.monotonic() >= deadline:
                        raise TimeoutError(
                            f"Timed out waiting for config file lock {self.lock_path}"
                        )
                    time.sleep(_LOCK_POLL_INTERVAL)
                try:
                    yield
                finally:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
        finally:
            self._lock.release()

    # ------------------------------------------------------- unlocked helpers

    def _read_unlocked(self) -> Dict:
        with open(self.config_path, "r") as f:
            config = yaml.safe_load(f)
        return config if config else {}

    def _write_unlocked(self, config: Dict) -> None:
        """Back up, then atomically replace config.yaml. Caller holds the lock."""
        existing = None
        if self.config_path.exists():
            existing = self.config_path.stat()
            self._create_backup()

        fd, tmp_name = tempfile.mkstemp(
            dir=str(self.config_path.parent), prefix=f".{self.config_path.name}.", suffix=".tmp"
        )
        try:
            # mkstemp already creates 0600; be explicit because this is the
            # security boundary for #67.
            os.fchmod(fd, CONFIG_FILE_MODE)
            if existing is not None:
                # Keep the original owner when we are allowed to (e.g. root).
                try:
                    os.fchown(fd, existing.st_uid, existing.st_gid)
                except OSError:
                    pass
            with os.fdopen(fd, "w") as f:
                yaml.dump(config, f, default_flow_style=False, sort_keys=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_name, self.config_path)
        except BaseException:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise

        self._fsync_dir()
        self._cleanup_old_backups()

    def _fsync_dir(self) -> None:
        """Persist the rename itself. Best effort: not every platform allows it."""
        try:
            dir_fd = os.open(self.config_path.parent, os.O_RDONLY)
        except OSError:
            return
        try:
            os.fsync(dir_fd)
        except OSError:
            pass
        finally:
            os.close(dir_fd)

    # ---------------------------------------------------------------- public

    def read_config(self, timeout: int = 5) -> Dict:
        """
        Read configuration file with locking.

        Args:
            timeout: Timeout in seconds for acquiring lock

        Returns:
            Configuration dictionary

        Raises:
            TimeoutError: If lock cannot be acquired within timeout
            FileNotFoundError: If config file doesn't exist
        """
        with self._locked(exclusive=False, timeout=timeout):
            if not self.config_path.exists():
                raise FileNotFoundError(f"Config file not found: {self.config_path}")
            return self._read_unlocked()

    def write_config(self, config: Dict, timeout: int = 5) -> None:
        """
        Write configuration file with locking and backup.

        The file is written to a temp file, fsynced and renamed over config.yaml,
        so readers never see a truncated or partial file.

        Args:
            config: Configuration dictionary to write
            timeout: Timeout in seconds for acquiring lock

        Raises:
            TimeoutError: If lock cannot be acquired within timeout
        """
        with self._locked(exclusive=True, timeout=timeout):
            self._write_unlocked(config)

    def update(
        self,
        mutator: Callable[[Dict], Optional[Dict]],
        validate: Optional[Validator] = None,
        timeout: int = 5,
    ) -> tuple[bool, Optional[str]]:
        """
        Atomically read, mutate and write the configuration.

        One exclusive lock is held from the read to the write, so concurrent
        updates from other threads or processes cannot be lost.

        Args:
            mutator: Called with the current config dict (``{}`` if the file does
                not exist). It may edit the dict in place and return None, or
                return a new dict to write. Raise an exception to abort; nothing
                is written and the message is returned as the error. It must not
                call back into this ConfigManager (the lock is not reentrant).
            validate: Optional validation function that returns
                (is_valid, error_message), run on the mutated config
            timeout: Timeout in seconds for acquiring lock

        Returns:
            Tuple of (success, error_message)

        Example:
            def add_reservation(config):
                config.setdefault("dhcp", {}).setdefault("reservations", []).append(r)

            ok, err = config_manager.update(add_reservation, validate_dhcp_config)
        """
        try:
            with self._locked(exclusive=True, timeout=timeout):
                config = self._read_unlocked() if self.config_path.exists() else {}
                result = mutator(config)
                if result is not None:
                    config = result

                if validate:
                    is_valid, error_msg = validate(config)
                    if not is_valid:
                        return False, error_msg

                self._write_unlocked(config)
                return True, None
        except Exception as e:
            return False, str(e)

    def update_section(
        self,
        section: str,
        data: Any,
        validate: Optional[Validator] = None,
        timeout: int = 5,
    ) -> tuple[bool, Optional[str]]:
        """
        Atomically update a single section of the configuration.

        This is the primary method for updating config sections. It ensures
        the read-modify-write operation is atomic, preventing race conditions.

        Args:
            section: Section name (e.g., 'dhcp', 'auth')
            data: Data to set for this section
            validate: Optional validation function that returns (is_valid, error_message)
            timeout: Timeout in seconds for acquiring lock

        Returns:
            Tuple of (success, error_message)

        Example:
            config_manager.update_section('dhcp', dhcp_data, validate_dhcp_config)
        """

        def _set(config: Dict) -> None:
            config[section] = data

        return self.update(_set, validate=validate, timeout=timeout)

    def update_multiple_sections(
        self,
        updates: Dict[str, Any],
        validate: Optional[Validator] = None,
        timeout: int = 5,
    ) -> tuple[bool, Optional[str]]:
        """
        Atomically update multiple sections of the configuration.

        Args:
            updates: Dictionary of section names to their new values
            validate: Optional validation function
            timeout: Timeout in seconds for acquiring lock

        Returns:
            Tuple of (success, error_message)
        """

        def _set_all(config: Dict) -> None:
            config.update(updates)

        return self.update(_set_all, validate=validate, timeout=timeout)

    # --------------------------------------------------------------- backups

    def _create_backup(self) -> Optional[Path]:
        """Create a uniquely named, 0600 backup of the config file."""
        if not self.config_path.exists():
            return None
        return create_unique_backup(
            self.config_path, self.config_path.parent, f"{self.config_path.stem}.backup."
        )

    def _cleanup_old_backups(self) -> None:
        """Remove old backup files, keeping only the most recent ones."""
        backup_pattern = f"{self.config_path.stem}.backup.*"
        backup_dir = self.config_path.parent

        def _age_key(p: Path) -> tuple[int, str]:
            try:
                return p.stat().st_mtime_ns, p.name
            except OSError:
                return 0, p.name

        # Find all backup files, newest first (name breaks mtime ties)
        backups = sorted(backup_dir.glob(backup_pattern), key=_age_key, reverse=True)

        # Remove old backups beyond max_backups
        for old_backup in backups[self.max_backups :]:
            try:
                old_backup.unlink()
            except Exception:
                pass  # Ignore errors during cleanup
