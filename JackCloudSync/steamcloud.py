#!/usr/bin/env python3
"""
JackSteamCloud — Download Steam Cloud files (including Auto-Cloud).
Uses Steam WebAuth + remotestorage web page.

Usage:
    steamcloud.py login <username> <password> [<2fa_code>]
    steamcloud.py list <appid>
    steamcloud.py download <appid> <output_dir>

Web session cookies persist ~1 month after login.
Output is JSON on stdout, logs on stderr.
"""

import sys
import os
import json
import pickle
import re
from pathlib import Path

DATA_DIR = Path.home() / "Library" / "Application Support" / "com.isaacmarovitz.Jack" / "SteamSession"
COOKIE_FILE = DATA_DIR / "webcookies.pkl"


def save_session(session):
    """Save requests session cookies to disk."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(COOKIE_FILE, 'wb') as f:
        pickle.dump(session.cookies, f)


def load_session():
    """Load a requests session from saved cookies."""
    if not COOKIE_FILE.exists():
        return None
    import requests
    session = requests.Session()
    try:
        with open(COOKIE_FILE, 'rb') as f:
            session.cookies = pickle.load(f)
        # Verify session is still valid
        resp = session.get('https://store.steampowered.com/account/', allow_redirects=False)
        if resp.status_code == 200 and 'steamLogin' in str(session.cookies):
            return session
        # Also check by looking for redirect to login
        if resp.status_code == 302:
            COOKIE_FILE.unlink(missing_ok=True)
            return None
        return session
    except Exception:
        COOKIE_FILE.unlink(missing_ok=True)
        return None


def cmd_login(username, password, twofactor_code=None):
    """Login via WebAuth and save session cookies."""
    from steam.webauth import WebAuth

    wa = WebAuth(username)
    try:
        session = wa.login(password=password, twofactor_code=twofactor_code or '')
    except KeyError as e:
        # Known bug: 'transfer_parameters' KeyError on success with 2FA
        # The login actually succeeded, session cookies are set
        if wa.logged_on or 'steamLoginSecure' in str(wa.session.cookies):
            session = wa.session
        else:
            print(json.dumps({"success": False, "error": f"Login KeyError: {e}"}))
            return 1
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))
        return 1

    if not session:
        print(json.dumps({"success": False, "error": "Login failed - no session"}))
        return 1

    save_session(session)

    # Try to extract steam ID from cookies
    steam_id = ""
    for cookie in session.cookies:
        if cookie.name == 'steamLoginSecure':
            # Format: steamID64%7C%7Ctoken
            parts = cookie.value.split('%7C')
            if parts:
                steam_id = parts[0]
            break

    # Save username
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "lastuser").write_text(username)

    print(json.dumps({"success": True, "steamID64": steam_id}))
    return 0


def get_cloud_files_from_web(session, appid):
    """Fetch cloud file list from Steam's remotestorage page."""
    url = f"https://store.steampowered.com/account/remotestorageapp/?appid={appid}"
    resp = session.get(url)

    if resp.status_code != 200:
        return None, f"HTTP {resp.status_code}"

    html = resp.text

    # Parse the file table from the HTML
    # Each file row has: filename, size, and a download link
    files = []

    # Pattern: look for file entries in the table
    # The page has rows with file info and download links
    rows = re.findall(
        r'<td[^>]*>\s*(.*?)\s*</td>\s*<td[^>]*>\s*([\d,]+)\s*</td>\s*<td[^>]*>.*?'
        r'href="(https://[^"]+)"',
        html, re.DOTALL
    )

    if not rows:
        # Try alternate pattern - some pages use different formatting
        # Look for individual file entries
        filenames = re.findall(r'<td class="[^"]*filename[^"]*"[^>]*>(.*?)</td>', html, re.DOTALL)
        sizes = re.findall(r'<td class="[^"]*size[^"]*"[^>]*>(.*?)</td>', html, re.DOTALL)
        links = re.findall(r'href="(https://steamcloud[^"]+)"', html)

        if not links:
            links = re.findall(r'href="(https://[^"]*cloud[^"]*download[^"]*)"', html, re.I)

        for i, link in enumerate(links):
            fname = filenames[i].strip() if i < len(filenames) else f"file_{i}"
            fname = re.sub(r'<[^>]+>', '', fname).strip()
            size = int(re.sub(r'[^\d]', '', sizes[i])) if i < len(sizes) else 0
            files.append({
                "filename": fname,
                "size": size,
                "url": link,
            })

    if not files and rows:
        for fname, size, url in rows:
            fname = re.sub(r'<[^>]+>', '', fname).strip()
            size = int(re.sub(r'[^\d]', '', size))
            files.append({
                "filename": fname,
                "size": size,
                "url": url,
            })

    # If still no files found, try a more aggressive parse
    if not files:
        # Find all download links
        all_links = re.findall(r'href="(https?://[^"]*)"[^>]*>\s*Download\s*</a>', html, re.I)
        if not all_links:
            all_links = re.findall(r'href="(https?://[^"]+)"[^>]*>.*?[Dd]ownload', html)

        # Find all filenames in the page (usually in td elements before the download link)
        all_rows = re.findall(
            r'<tr[^>]*>(.*?)</tr>',
            html, re.DOTALL
        )

        for row_html in all_rows:
            link_match = re.search(r'href="(https?://[^"]+)"', row_html)
            if not link_match:
                continue

            tds = re.findall(r'<td[^>]*>(.*?)</td>', row_html, re.DOTALL)
            if len(tds) >= 2:
                fname = re.sub(r'<[^>]+>', '', tds[0]).strip()
                size_str = re.sub(r'[^\d]', '', re.sub(r'<[^>]+>', '', tds[1]))
                size = int(size_str) if size_str else 0
                files.append({
                    "filename": fname,
                    "size": size,
                    "url": link_match.group(1),
                })

    return files, None


def cmd_list(appid):
    """List all cloud files for an app."""
    session = load_session()
    if not session:
        print(json.dumps({"error": "No saved session. Run 'login' first.", "count": 0}))
        return 1

    files, error = get_cloud_files_from_web(session, appid)
    if error:
        print(json.dumps({"error": error, "count": 0}))
        return 1

    # Output without URLs (for listing)
    output_files = [{"filename": f["filename"], "size": f["size"]} for f in files]
    print(json.dumps({"files": output_files, "count": len(output_files)}))
    return 0


def cmd_download(appid, output_dir):
    """Download all cloud files for an app."""
    session = load_session()
    if not session:
        print(json.dumps({"error": "No saved session. Run 'login' first.", "downloaded": 0}))
        return 1

    files, error = get_cloud_files_from_web(session, appid)
    if error:
        print(json.dumps({"error": error, "downloaded": 0}))
        return 1

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    downloaded = 0
    for f in files:
        if f["size"] <= 0:
            continue

        url = f["url"]
        filename = f["filename"]

        dest = out / filename
        dest.parent.mkdir(parents=True, exist_ok=True)

        try:
            resp = session.get(url, stream=True)
            if resp.status_code == 200:
                with open(dest, 'wb') as fp:
                    for chunk in resp.iter_content(chunk_size=65536):
                        fp.write(chunk)
                downloaded += 1
                print(f"Downloaded: {filename} ({f['size']} bytes)", file=sys.stderr)
            else:
                print(f"Failed to download {filename}: HTTP {resp.status_code}", file=sys.stderr)
        except Exception as e:
            print(f"Failed to download {filename}: {e}", file=sys.stderr)

    print(json.dumps({"downloaded": downloaded}))
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1

    cmd = sys.argv[1]

    if cmd == "login":
        if len(sys.argv) < 4:
            print("Usage: steamcloud.py login <username> <password> [<2fa_code>]", file=sys.stderr)
            return 1
        return cmd_login(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)

    elif cmd == "list":
        if len(sys.argv) < 3:
            print("Usage: steamcloud.py list <appid>", file=sys.stderr)
            return 1
        return cmd_list(int(sys.argv[2]))

    elif cmd == "download":
        if len(sys.argv) < 4:
            print("Usage: steamcloud.py download <appid> <output_dir>", file=sys.stderr)
            return 1
        return cmd_download(int(sys.argv[2]), sys.argv[3])

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
