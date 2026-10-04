#!/usr/bin/env python3
"""Verify the pinned skill files and canonical links without network access."""
import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    lock = json.loads((root / "docs/agents/matt-pocock-skills.lock.json").read_text())
    failures = []
    files = 0
    for skill in lock["skills"]:
        directory = root / skill["installed_path"]
        expected = {item["path"] for item in skill["files"]}
        actual = {p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file()}
        if expected != actual:
            failures.append(f"{skill['name']}: file inventory differs from lock")
        for item in skill["files"]:
            path = directory / item["path"]
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
                failures.append(f"{skill['name']}/{item['path']}: missing or changed; update the lock for intentional edits")
            files += 1
    if len(lock["skills"]) != lock["skill_count"] or files != lock["file_count"]:
        failures.append("lock counts differ from its inventory")
    license_path = root / lock["license_path"]
    if not license_path.is_file() or not license_path.read_text().strip():
        failures.append("upstream licence is missing")
    for location in (root / "agent/skills", root / ".claude/skills"):
        for alias in location.iterdir():
            canonical = root / ".agents/skills" / alias.name
            if not alias.is_symlink() or alias.resolve() != canonical.resolve() or not canonical.is_dir():
                failures.append(f"{alias.relative_to(root)}: expected a link to .agents/skills/{alias.name}")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Verified {len(lock['skills'])} skills, {files} files and canonical skill links.")


if __name__ == "__main__":
    main()
