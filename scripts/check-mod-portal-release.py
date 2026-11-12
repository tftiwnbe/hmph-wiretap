#!/usr/bin/env python3
"""Skip stale or already-published tag uploads; fail closed on lookup errors."""

import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def version_number(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("Expected a numeric major.minor.patch version")
    return tuple(map(int, value.split(".")))


def should_publish():
    info = json.loads(Path("mod/hmph-wiretap/info.json").read_text())
    name, version = info["name"], info["version"]
    current = version_number(version)
    # Read the server's tags, not a shallow checkout's incomplete tag list.
    tags = subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", "origin"],
        check=True, capture_output=True, text=True, timeout=30,
    ).stdout
    versions = []
    for line in tags.splitlines():
        match = re.search(r"\srefs/tags/v(\d+\.\d+\.\d+)$", line)
        if match:
            versions.append(version_number(match.group(1)))
    if not versions or current not in versions:
        raise ValueError("Current release tag is not present on origin")
    newest = max(versions)
    if newest > current:
        print(f"Skipping {version}: origin already has a newer release tag.")
        return False

    # Portal responses can be cached after an upload. A unique query avoids
    # treating a stale release list as permission to publish an older version.
    url = f"https://mods.factorio.com/api/mods/{name}?release_guard={time.time_ns()}"
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=30) as response:
        releases = json.load(response)["releases"]
    published = [version_number(release["version"]) for release in releases]
    if current in published:
        print(f"Skipping {version}: this version is already on the Mod Portal.")
        return False
    if published and max(published) > current:
        print(f"Skipping {version}: a newer version is already on the Mod Portal.")
        return False
    print(f"Publishing {name} {version}: newest tag and not yet uploaded.")
    return True


def main():
    # Explicit false output also makes a failed lookup fail closed in the job.
    output = Path(sys.argv[1])
    with output.open("a") as stream:
        stream.write("publish=false\n")
    try:
        publish = should_publish()
    except Exception as error:
        # Do not log credential-bearing URLs or subprocess output on failures.
        print(f"Cannot establish safe release order ({type(error).__name__}); refusing upload.", file=sys.stderr)
        return 1
    if publish:
        with output.open("a") as stream:
            stream.write("publish=true\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
