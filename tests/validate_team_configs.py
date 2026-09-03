#!/usr/bin/env python3
"""Validate every teams/*/team.yaml against teams/schema/team.schema.json.

Run before Terraform executes at all - a team's config must satisfy the
contract before we spend a single terraform plan on it. Exits non-zero if
any team.yaml is missing, malformed, or fails the schema.
"""

import glob
import json
import os
import sys

import jsonschema
import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_PATH = os.path.join(REPO_ROOT, "teams", "schema", "team.schema.json")
TEAM_GLOB = os.path.join(REPO_ROOT, "teams", "*", "team.yaml")


def load_schema():
    with open(SCHEMA_PATH) as f:
        return json.load(f)


def find_team_files():
    return sorted(glob.glob(TEAM_GLOB))


def main():
    schema = load_schema()
    team_files = find_team_files()

    if not team_files:
        print("No teams/*/team.yaml files found.")
        return 1

    failures = []

    for path in team_files:
        rel_path = os.path.relpath(path, REPO_ROOT)
        try:
            with open(path) as f:
                doc = yaml.safe_load(f)
        except yaml.YAMLError as e:
            failures.append((rel_path, f"invalid YAML: {e}"))
            continue

        try:
            jsonschema.validate(instance=doc, schema=schema)
        except jsonschema.ValidationError as e:
            failures.append((rel_path, e.message))
            continue

        team_dir = os.path.basename(os.path.dirname(path))
        if doc.get("team") != team_dir:
            failures.append(
                (rel_path, f"'team' field ('{doc.get('team')}') must match its directory name ('{team_dir}')")
            )
            continue

        print(f"OK    {rel_path}")

    if failures:
        print()
        for rel_path, message in failures:
            print(f"FAIL  {rel_path}: {message}")
        print(f"\n{len(failures)} of {len(team_files)} team config(s) failed schema validation.")
        return 1

    print(f"\nAll {len(team_files)} team config(s) passed schema validation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
