#!/usr/bin/env python3

import re
import subprocess
import sys
from pathlib import Path


CONFIG_PATH = "unifi-camera-voice/config.yaml"
VERSION_PATTERN = re.compile(r'^version:\s*["\']?(\d+)\.(\d+)\.(\d+)["\']?\s*$', re.MULTILINE)
ZERO_SHA = "0" * 40


def parse_version(config: str, source: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.search(config)
    if not match:
        raise ValueError(f"{source} does not contain a semantic app version")
    return tuple(int(part) for part in match.groups())


def format_version(version: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in version)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} BASE_GIT_REF", file=sys.stderr)
        return 2

    base_ref = sys.argv[1]
    if not base_ref or base_ref == ZERO_SHA:
        print("No prior revision is available; skipping app version comparison.")
        return 0

    current_config = Path(CONFIG_PATH).read_text(encoding="utf-8")
    try:
        base_config = subprocess.run(
            ["git", "show", f"{base_ref}:{CONFIG_PATH}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except subprocess.CalledProcessError:
        print(
            f"{CONFIG_PATH} does not exist at {base_ref}; treating this as the "
            "initial app release."
        )
        return 0

    try:
        base_version = parse_version(base_config, f"{base_ref}:{CONFIG_PATH}")
        current_version = parse_version(current_config, CONFIG_PATH)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    if current_version <= base_version:
        print(
            "The Home Assistant app version must increase with every change "
            f"merged to main (base: {format_version(base_version)}, current: "
            f"{format_version(current_version)}).",
            file=sys.stderr,
        )
        return 1

    print(
        f"App version increased from {format_version(base_version)} to "
        f"{format_version(current_version)}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
