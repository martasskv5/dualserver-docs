#!/usr/bin/env python3
"""
Authentik → GitLab CE Group Sync Webhook Server
Listens for Authentik login events and syncs user group memberships to GitLab.
"""

import os
import re
import sys
import hmac
import hashlib
import logging
from functools import wraps

import requests
from flask import Flask, request, jsonify

# ─── Configuration ─────────────────────────────────────────────────────────────

# Authentik
AUTHENTIK_URL = os.environ.get(
    "AUTHENTIK_URL",      "https://authentik.yourdomain.com")
AUTHENTIK_TOKEN = os.environ.get(
    "AUTHENTIK_TOKEN",    "")   # Service account API token
AUTHENTIK_WEBHOOK_SECRET = os.environ.get(
    "AUTHENTIK_WEBHOOK_SECRET", "")  # Optional HMAC verification

# GitLab
GITLAB_URL = os.environ.get(
    "GITLAB_URL",         "https://gitlab.yourdomain.com")
# Admin personal/group access token
GITLAB_TOKEN = os.environ.get("GITLAB_TOKEN",       "")

# Sync settings
SYNC_ON_LOGIN = os.environ.get("SYNC_ON_LOGIN",      "true").lower() == "true"
SYNC_ON_USER_WRITE = os.environ.get(
    "SYNC_ON_USER_WRITE",   "true").lower() == "true"

# Group mapping: Authentik group suffix → (GitLab group path, access_level)
# Access levels: 10=Guest, 20=Reporter, 30=Developer, 40=Maintainer, 50=Owner
GROUP_MAP = {
    "lectors":  ("{year_group}/lectors", 50),   # Owner
    "students": ("{year_group}/students", 30),   # Developer
}

# Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("gitlab-sync")

app = Flask(__name__)

# ─── GitLab API Client ───────────────────────────────────────────────────────


class GitLabAPI:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.headers = {
            "PRIVATE-TOKEN": token,
            "Content-Type": "application/json",
        }

    def _request(self, method: str, endpoint: str, **kwargs):
        url = f"{self.base_url}/api/v4{endpoint}"
        try:
            resp = requests.request(
                method, url, headers=self.headers, timeout=30, **kwargs)
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            return resp.json() if resp.text else None
        except requests.exceptions.RequestException as e:
            logger.error(f"GitLab API error: {e}")
            raise

    def get_user_by_email(self, email: str):
        """Find GitLab user by email."""
        users = self._request("GET", "/users", params={"search": email})
        if users:
            for u in users:
                if u.get("email") == email or u.get("public_email") == email:
                    return u
        return None

    def get_user_by_username(self, username: str):
        """Find GitLab user by username."""
        user = self._request("GET", f"/users/{username}")
        return user

    def get_group(self, path: str):
        """Get group by full path."""
        # URL-encode the path
        encoded = path.replace("/", "%2F")
        return self._request("GET", f"/groups/{encoded}")

    def list_group_members(self, group_id: int):
        """List all direct members of a group."""
        members = []
        page = 1
        while True:
            chunk = self._request(
                "GET", f"/groups/{group_id}/members", params={"page": page, "per_page": 100})
            if not chunk:
                break
            members.extend(chunk)
            if len(chunk) < 100:
                break
            page += 1
        return members

    def add_group_member(self, group_id: int, user_id: int, access_level: int):
        """Add or update a group member."""
        existing = self._request(
            "GET", f"/groups/{group_id}/members/{user_id}")
        if existing:
            # Update if level changed
            if existing.get("access_level") != access_level:
                self._request("PUT", f"/groups/{group_id}/members/{user_id}",
                              json={"access_level": access_level})
                logger.info(
                    f"Updated user {user_id} in group {group_id} to level {access_level}")
            return existing

        # Add new member
        return self._request("POST", f"/groups/{group_id}/members",
                             json={"user_id": user_id, "access_level": access_level})

    def remove_group_member(self, group_id: int, user_id: int):
        """Remove a member from a group."""
        self._request("DELETE", f"/groups/{group_id}/members/{user_id}")
        logger.info(f"Removed user {user_id} from group {group_id}")


# ─── Authentik API Client ────────────────────────────────────────────────────

class AuthentikAPI:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

    def get_user_groups(self, user_pk: int):
        """Fetch all groups for a user from Authentik."""
        # Get user details including groups
        user = self._request("GET", f"/api/v3/core/users/{user_pk}/")
        if not user:
            return []

        # Groups are in the 'ak_groups' field
        groups = user.get("ak_groups", [])
        return [g.get("name") for g in groups if g.get("name")]

    def _request(self, method: str, endpoint: str, **kwargs):
        url = f"{self.base_url}{endpoint}"
        try:
            resp = requests.request(
                method, url, headers=self.headers, timeout=30, **kwargs)
            resp.raise_for_status()
            return resp.json() if resp.text else None
        except requests.exceptions.RequestException as e:
            logger.error(f"Authentik API error: {e}")
            raise


# ─── Sync Logic ──────────────────────────────────────────────────────────────

def parse_year_group_groups(ak_groups: list[str]):
    """
    Parse Authentik groups and return dict of:
    {year_group: {'lectors': bool, 'students': bool}}
    """
    result = {}
    is_lector = "Lectors" in ak_groups
    is_student = "Students" in ak_groups

    for g in ak_groups:
        if g.startswith("sk"):
            result[g] = {
                "lectors": is_lector,
                "students": is_student,
            }
    return result


def sync_user_to_gitlab(gitlab: GitLabAPI, authentik: AuthentikAPI,
                        username: str, email: str, user_pk: int):
    """
    Main sync function: reads user's Authentik groups, ensures GitLab membership.
    """
    logger.info(f"Syncing user: {username} (pk={user_pk})")

    # 1. Get user's groups from Authentik
    ak_groups = authentik.get_user_groups(user_pk)
    logger.info(f"Authentik groups for {username}: {ak_groups}")

    # 2. Determine desired GitLab memberships
    year_groups = parse_year_group_groups(ak_groups)
    if not year_groups:
        logger.warning(f"No year groups found for {username}")
        return

    # 3. Find GitLab user
    gitlab_user = gitlab.get_user_by_username(username)
    if not gitlab_user:
        gitlab_user = gitlab.get_user_by_email(email)

    if not gitlab_user:
        logger.error(f"GitLab user not found for {username} / {email}")
        return

    gitlab_user_id = gitlab_user["id"]
    logger.info(
        f"Found GitLab user: {gitlab_user['username']} (id={gitlab_user_id})")

    # 4. For each year group, ensure membership in lectors/students subgroups
    for year_group, roles in year_groups.items():
        for role, should_be_member in roles.items():
            if not should_be_member:
                continue

            gitlab_path, access_level = GROUP_MAP[role]
            gitlab_path = gitlab_path.format(year_group=year_group)

            # Find the GitLab group
            gl_group = gitlab.get_group(gitlab_path)
            if not gl_group:
                logger.error(f"GitLab group not found: {gitlab_path}")
                continue

            # Add/update member
            gitlab.add_group_member(
                gl_group["id"], gitlab_user_id, access_level)
            logger.info(
                f"Ensured {username} is member of {gitlab_path} with level {access_level}")

    # 5. Optional: Remove from groups user shouldn't be in
    # (This requires tracking all possible groups — skip for now, or implement cleanup)

    logger.info(f"Sync complete for {username}")


# ─── Flask Routes ─────────────────────────────────────────────────────────────

def verify_webhook_signature(request_data: bytes, signature: str, secret: str) -> bool:
    """Verify Authentik webhook HMAC signature."""
    if not secret:
        return True  # Skip verification if no secret configured

    expected = hmac.new(secret.encode(), request_data,
                        hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/sync", methods=["POST"])
def handle_sync():
    """Handle incoming Authentik webhook."""
    # Optional: verify signature
    signature = request.headers.get("X-Authentik-Signature", "")
    if AUTHENTIK_WEBHOOK_SECRET:
        if not verify_webhook_signature(request.get_data(), signature, AUTHENTIK_WEBHOOK_SECRET):
            logger.warning("Invalid webhook signature")
            return jsonify({"error": "Invalid signature"}), 403

    payload = request.get_json(silent=True) or {}
    action = payload.get("action", "")

    logger.info(f"Received webhook: action={action}")

    # Filter events
    if action == "login" and not SYNC_ON_LOGIN:
        return jsonify({"skipped": True, "reason": "login sync disabled"}), 200
    if action == "user_write" and not SYNC_ON_USER_WRITE:
        return jsonify({"skipped": True, "reason": "user_write sync disabled"}), 200
    if action not in ("login", "user_write"):
        return jsonify({"skipped": True, "reason": "unsupported action"}), 200

    # Extract user info from webhook payload
    user_info = payload.get("user", {})
    user_pk = user_info.get("pk")
    username = user_info.get("username")
    email = user_info.get("email")

    if not user_pk:
        logger.error("No user PK in webhook payload")
        return jsonify({"error": "No user PK"}), 400

    # Initialize API clients
    gitlab = GitLabAPI(GITLAB_URL, GITLAB_TOKEN)
    authentik = AuthentikAPI(AUTHENTIK_URL, AUTHENTIK_TOKEN)

    try:
        sync_user_to_gitlab(gitlab, authentik, username, email, user_pk)
        return jsonify({"success": True}), 200
    except Exception as e:
        logger.exception("Sync failed")
        return jsonify({"error": str(e)}), 500


@app.route("/sync-user/<username>", methods=["POST"])
def manual_sync(username: str):
    """Manual sync endpoint for a specific user."""
    # This would need to look up the user in Authentik first
    # For now, return a placeholder
    return jsonify({"message": f"Manual sync for {username} not yet implemented"}), 501


# ─── Main ────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Validate config
    if not AUTHENTIK_TOKEN:
        logger.error("AUTHENTIK_TOKEN not set")
        sys.exit(1)
    if not GITLAB_TOKEN:
        logger.error("GITLAB_TOKEN not set")
        sys.exit(1)

    logger.info("Starting GitLab sync webhook server")
    logger.info(f"Authentik: {AUTHENTIK_URL}")
    logger.info(f"GitLab: {GITLAB_URL}")

    # Run with gunicorn in production: gunicorn -w 4 -b 0.0.0.0:5000 gitlab_sync:app
    app.run(host="0.0.0.0", port=5000, debug=False)
