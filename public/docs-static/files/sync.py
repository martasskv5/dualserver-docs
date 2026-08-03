#!/usr/bin/env python3
"""
authentik → GitLab CE Group Sync

Synchronizes year-based groups from authentik to GitLab CE.
- Year groups (sk25-26, sk26-27, etc.) become top-level GitLab groups
- Lectors get Maintainer access (full repo access + group management)
- Students get Developer access (can push code, create repos, invite collaborators)
- Users removed from authentik groups are removed from GitLab groups
- Private projects are forced to Internal visibility (so everyone can see them)

Run this inside your Docker Compose stack as a scheduled service.
"""

import os
import sys
import time
import logging
import requests
from typing import Dict, List, Optional, Set

# ── Logging ──────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("ak-gl-sync")

# ── Configuration ──────────────────────────────────────────────────────────
AUTHENTIK_URL = os.environ.get("AUTHENTIK_URL", "http://authentik-server:9000")
AUTHENTIK_TOKEN = os.environ.get("AUTHENTIK_TOKEN")
GITLAB_URL = os.environ.get("GITLAB_URL", "https://git.pve99.internal")
GITLAB_TOKEN = os.environ.get("GITLAB_TOKEN")

# Parent group names in authentik
LECTOR_GROUP = os.environ.get("LECTOR_GROUP", "Lectors")
STUDENT_GROUP = os.environ.get("STUDENT_GROUP", "Students")
YEAR_PREFIX = os.environ.get("YEAR_PREFIX", "sk")

# Sync interval in seconds (0 = run once and exit)
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "300"))

# If True, only print what would change without applying
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

# GitLab access levels
GUEST = 10
REPORTER = 20
DEVELOPER = 30
MAINTAINER = 40
OWNER = 50

LECTOR_ROLE = MAINTAINER   # Can manage group, access all repos, change settings
STUDENT_ROLE = DEVELOPER   # Can push code, create repos, invite up to Developer


# ── Authentik Client ─────────────────────────────────────────────────────
class AuthentikClient:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def _get(self, endpoint: str, params: dict = None) -> dict:
        url = f"{self.base_url}{endpoint}"
        resp = requests.get(url, headers=self.headers, params=params, timeout=30)
        resp.raise_for_status()
        return resp.json()

    def get_all_groups(self) -> Dict[str, dict]:
        """Fetch all authentik groups: {pk: group_data}"""
        groups = {}
        page = 1
        page_size = 100
        while True:
            try:
                data = self._get("/api/v3/core/groups/", {
                    "page": page,
                    "page_size": page_size,
                })
            except requests.HTTPError as e:
                if e.response.status_code == 404 and page > 1:
                    break
                raise

            results = data.get("results", [])
            for g in results:
                groups[str(g["pk"])] = g

            # Stop if we got fewer results than requested — no more pages
            if len(results) < page_size:
                break

            # Also stop if DRF explicitly says there's no next page
            if not data.get("next") and not data.get("pagination", {}).get("next"):
                break

            page += 1
            if page > 100:
                break
        return groups

    def get_all_users(self) -> List[dict]:
        """Fetch all authentik users with their group memberships."""
        users = []
        page = 1
        page_size = 100
        while True:
            try:
                data = self._get("/api/v3/core/users/", {
                    "page": page,
                    "page_size": page_size,
                })
            except requests.HTTPError as e:
                if e.response.status_code == 404 and page > 1:
                    break
                raise

            batch = data.get("results", [])
            if not batch:
                break
            users.extend(batch)

            if len(batch) < page_size:
                break

            if not data.get("next") and not data.get("pagination", {}).get("next"):
                break

            page += 1
            if page > 100:
                break
        return users


# ── GitLab Client ────────────────────────────────────────────────────────
class GitLabClient:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.headers = {
            "PRIVATE-TOKEN": token,
            "Content-Type": "application/json",
        }

    def _get(self, endpoint: str, params: dict = None) -> List[dict]:
        url = f"{self.base_url}/api/v4{endpoint}"
        items = []
        page = 1
        while True:
            p = dict(params) if params else {}
            p["page"] = page
            p["per_page"] = 100
            resp = requests.get(url, headers=self.headers, params=p, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            if isinstance(data, dict) and "error" in data:
                raise RuntimeError(f"GitLab API error: {data}")
            if not data:
                break
            items.extend(data)
            if len(data) < 100:
                break
            page += 1
            if page > 100:
                break
        return items

    def _post(self, endpoint: str, data: dict) -> dict:
        url = f"{self.base_url}/api/v4{endpoint}"
        if DRY_RUN:
            logger.info(f"[DRY-RUN] POST {endpoint} -> {data}")
            return {}
        resp = requests.post(url, headers=self.headers, json=data, timeout=30)
        if resp.status_code == 409:
            logger.debug(f"Conflict on POST {endpoint}: probably already exists")
            return resp.json() if resp.text else {}
        resp.raise_for_status()
        return resp.json()

    def _put(self, endpoint: str, data: dict) -> dict:
        url = f"{self.base_url}/api/v4{endpoint}"
        if DRY_RUN:
            logger.info(f"[DRY-RUN] PUT {endpoint} -> {data}")
            return {}
        resp = requests.put(url, headers=self.headers, json=data, timeout=30)
        resp.raise_for_status()
        return resp.json()

    def _delete(self, endpoint: str) -> None:
        url = f"{self.base_url}/api/v4{endpoint}"
        if DRY_RUN:
            logger.info(f"[DRY-RUN] DELETE {endpoint}")
            return
        resp = requests.delete(url, headers=self.headers, timeout=30)
        if resp.status_code == 404:
            return
        resp.raise_for_status()

    # Groups
    def get_groups(self) -> List[dict]:
        return self._get("/groups")

    def create_group(self, name: str, path: str) -> dict:
        """Create a top-level group with Internal visibility."""
        return self._post("/groups", {
            "name": name,
            "path": path,
            "visibility": "internal",
            "project_creation_level": "developer",
            "subgroup_creation_level": "maintainer",
            "require_two_factor_authentication": False,
        })

    def get_group_members(self, group_id: int) -> List[dict]:
        return self._get(f"/groups/{group_id}/members")

    def add_group_member(self, group_id: int, user_id: int, access_level: int) -> dict:
        return self._post(f"/groups/{group_id}/members", {
            "user_id": user_id,
            "access_level": access_level,
        })

    def update_group_member(self, group_id: int, user_id: int, access_level: int) -> dict:
        return self._put(f"/groups/{group_id}/members/{user_id}", {
            "access_level": access_level,
        })

    def remove_group_member(self, group_id: int, user_id: int) -> None:
        self._delete(f"/groups/{group_id}/members/{user_id}")

    # Users
    def get_users(self) -> List[dict]:
        return self._get("/users")

    # Projects (for visibility enforcement)
    def get_group_projects(self, group_id: int) -> List[dict]:
        return self._get(f"/groups/{group_id}/projects")

    def update_project(self, project_id: int, data: dict) -> dict:
        return self._put(f"/projects/{project_id}", data)


# ── Core Logic ────────────────────────────────────────────────────────────
def build_desired_state(
    ak_groups: Dict[str, dict],
    ak_users: List[dict]
) -> Dict[str, Dict[str, int]]:
    """
    Determine what GitLab should look like based on authentik data.
    Returns: {gitlab_group_name: {gitlab_username: access_level}}
    """
    desired: Dict[str, Dict[str, int]] = {}

    for user in ak_users:
        username = user.get("username")
        if not username:
            continue

        # Resolve group PKs to names
        user_group_pks = [str(g) for g in user.get("groups", [])]
        user_group_names = set()
        for pk in user_group_pks:
            grp = ak_groups.get(pk)
            if grp:
                user_group_names.add(grp.get("name", ""))

        # Determine user type
        is_lector = LECTOR_GROUP in user_group_names
        is_student = STUDENT_GROUP in user_group_names

        if not (is_lector or is_student):
            continue  # Not part of our sync scope

        role = LECTOR_ROLE if is_lector else STUDENT_ROLE

        # Find year groups this user belongs to
        for pk in user_group_pks:
            grp = ak_groups.get(pk)
            if not grp:
                continue
            name = grp.get("name", "")
            if not name.startswith(YEAR_PREFIX):
                continue

            if name not in desired:
                desired[name] = {}
            desired[name][username] = role

    return desired


def sync():
    if not AUTHENTIK_TOKEN:
        logger.error("AUTHENTIK_TOKEN is not set")
        sys.exit(1)
    if not GITLAB_TOKEN:
        logger.error("GITLAB_TOKEN is not set")
        sys.exit(1)

    ak = AuthentikClient(AUTHENTIK_URL, AUTHENTIK_TOKEN)
    gl = GitLabClient(GITLAB_URL, GITLAB_TOKEN)

    logger.info("=" * 60)
    logger.info("Starting authentik → GitLab sync")
    if DRY_RUN:
        logger.info("*** DRY RUN MODE — no changes will be applied ***")

    # ── Fetch authentik data ─────────────────────────────────────────────
    logger.info("Fetching authentik groups...")
    ak_groups = ak.get_all_groups()
    logger.info(f"  Found {len(ak_groups)} authentik groups")

    logger.info("Fetching authentik users...")
    ak_users = ak.get_all_users()
    logger.info(f"  Found {len(ak_users)} authentik users")

    desired = build_desired_state(ak_groups, ak_users)
    logger.info(f"  Desired GitLab groups: {sorted(desired.keys())}")

    # ── Fetch GitLab data ────────────────────────────────────────────────
    logger.info("Fetching GitLab groups...")
    gl_groups_raw = gl.get_groups()
    gl_groups = {g["path"]: g for g in gl_groups_raw}
    logger.info(f"  Found {len(gl_groups)} GitLab groups")

    logger.info("Fetching GitLab users...")
    gl_users_raw = gl.get_users()
    gl_users = {u["username"]: u for u in gl_users_raw}
    logger.info(f"  Found {len(gl_users)} GitLab users")

    # ── Create missing groups ────────────────────────────────────────────
    for group_name in desired:
        if group_name not in gl_groups:
            logger.info(f"Creating GitLab group: {group_name}")
            try:
                new_group = gl.create_group(group_name, group_name)
                gl_groups[group_name] = new_group
            except Exception as e:
                logger.error(f"  Failed to create group {group_name}: {e}")

    # ── Sync memberships per group ───────────────────────────────────────
    for group_name, desired_members in desired.items():
        group = gl_groups.get(group_name)
        if not group:
            logger.warning(f"Group {group_name} not available, skipping")
            continue

        group_id = group["id"]

        try:
            current_members_list = gl.get_group_members(group_id)
            current_members = {m["username"]: m for m in current_members_list}
        except Exception as e:
            logger.error(f"  Failed to fetch members for {group_name}: {e}")
            continue

        # Add or update members
        for username, role in desired_members.items():
            gl_user = gl_users.get(username)
            if not gl_user:
                logger.warning(
                    f"  User '{username}' not found in GitLab yet — "
                    f"they need to log in via OIDC first"
                )
                continue

            current = current_members.get(username)
            if not current:
                logger.info(f"  + Adding {username} to {group_name} (role={role})")
                try:
                    gl.add_group_member(group_id, gl_user["id"], role)
                except Exception as e:
                    logger.error(f"    Failed: {e}")
            elif current["access_level"] != role:
                logger.info(
                    f"  ~ Updating {username} in {group_name} "
                    f"({current['access_level']} → {role})"
                )
                try:
                    gl.update_group_member(group_id, gl_user["id"], role)
                except Exception as e:
                    logger.error(f"    Failed: {e}")
            else:
                logger.debug(f"  = {username} already correct in {group_name}")

        # Remove members who should not be there
        for username, current in current_members.items():
            # Never remove Owners — they might be admin/service accounts
            if current.get("access_level") == OWNER:
                continue

            if username not in desired_members:
                logger.info(f"  - Removing {username} from {group_name}")
                try:
                    gl.remove_group_member(group_id, current["user_id"])
                except Exception as e:
                    logger.error(f"    Failed: {e}")

    # ── Enforce project visibility ───────────────────────────────────────
    logger.info("Enforcing Internal visibility on all projects...")
    for group_name in desired:
        group = gl_groups.get(group_name)
        if not group:
            continue
        group_id = group["id"]
        try:
            projects = gl.get_group_projects(group_id)
            for proj in projects:
                if proj.get("visibility") == "private":
                    logger.info(
                        f"  Changing project '{proj['path_with_namespace']}' "
                        f"from Private → Internal"
                    )
                    try:
                        gl.update_project(proj["id"], {"visibility": "internal"})
                    except Exception as e:
                        logger.error(f"    Failed: {e}")
        except Exception as e:
            logger.error(f"  Failed to list projects for {group_name}: {e}")

    logger.info("Sync complete")
    logger.info("=" * 60)


def main():
    if SYNC_INTERVAL <= 0:
        sync()
    else:
        logger.info(f"Running every {SYNC_INTERVAL} seconds (Ctrl+C to stop)")
        while True:
            try:
                sync()
            except Exception as e:
                logger.error(f"Sync failed: {e}")
            time.sleep(SYNC_INTERVAL)


if __name__ == "__main__":
    main()
