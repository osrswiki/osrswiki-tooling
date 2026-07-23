import os
import subprocess
from pathlib import Path


STORAGE_HELPER = Path(__file__).resolve().parents[2] / "scripts" / "shared" / "local-artifact-root.sh"


def _helper_path(command, path=None):
    args = [str(STORAGE_HELPER), command]
    if path is not None:
        args.append(str(path))
    output = subprocess.check_output(args, text=True, env=os.environ)
    return Path(output.strip())


def validate_local_artifact_path(path):
    """Return a canonical path only when it stays under the verified root."""
    try:
        return _helper_path("validate-path", Path(path).expanduser().resolve())
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            f"Path is outside the verified machine-local artifact root: {path}"
        ) from error


def find_cache_base(start_path):
    """Find the verified machine-local cache without synced fallbacks."""
    configured = os.environ.get("OSRS_CACHE_ROOT")
    if configured:
        cache = Path(configured).expanduser().resolve()
        try:
            validated = validate_local_artifact_path(cache)
        except RuntimeError as error:
            raise RuntimeError(
                f"Configured OSRS_CACHE_ROOT is outside the verified local root: {cache}"
            ) from error
        if not validated.is_dir():
            raise RuntimeError(f"Configured OSRS_CACHE_ROOT does not exist: {validated}")
        return validated

    try:
        return _helper_path("cache")
    except subprocess.CalledProcessError as error:
        start = Path(start_path).resolve()
        raise RuntimeError(
            f"Could not resolve the verified machine-local cache from {start}"
        ) from error
