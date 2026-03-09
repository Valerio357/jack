#!/usr/bin/env python3
"""
JackSteam — Steam Cloud CLI for Jack.
Replaces JackCloudSync (C) and Steam.app dependency.

Commands:
    login <user> <pass> [<2fa>]           → JSON: {steamID64, accountName, refreshToken}
    token-login <refresh_token>           → JSON: {success, steamID64}
    licenses <refresh_token>              → JSON: {appids: [...], count}
    list <appid> <refresh_token>          → JSON: {files: [...], count}
    download <appid> <dir> <refresh_token>    → JSON: {downloaded}
    upload <appid> <file> <name> <refresh_token> → JSON: {success}
    sync-down <appid> <bottle> <refresh_token>   → JSON: {downloaded}
    sync-up <appid> <bottle> <refresh_token>     → JSON: {uploaded}

All output is JSON on stdout, logs on stderr.
"""

import gevent
import gevent.monkey
gevent.monkey.patch_socket()
gevent.monkey.patch_select()
gevent.monkey.patch_ssl()

import sys
import os
import json
import hashlib
import time
import base64
import socket
import urllib.request
import urllib.parse
from pathlib import Path

from steam.client import SteamClient, EResult, EMsg, MsgProto
from steam.core.msg import MsgProto as MsgProtoClass
from steam.enums import EOSType
from steam.steamid import SteamID

DATA_DIR = Path.home() / "Library" / "Application Support" / "com.isaacmarovitz.Jack" / "SteamSession"
DATA_DIR.mkdir(parents=True, exist_ok=True)

# Auto-Cloud root type → Wine prefix subpath
ROOT_MAP = {
    1: "drive_c/users/crossover/Documents",
    2: "drive_c/users/crossover/Documents",
    3: "drive_c/users/crossover/AppData/Local",
    4: "drive_c/users/crossover/AppData/Roaming",
    5: "drive_c/users/crossover/AppData/LocalLow",
    6: "drive_c/users/crossover/Saved Games",
}


def log(msg):
    print(msg, file=sys.stderr)


def output(data):
    print(json.dumps(data))


# ─── Authentication (protobuf-encoded Web API) ───────────────────────────────

from steam.protobufs import steammessages_auth_pb2 as auth_pb


def _steam_api_post(service, method, request_proto):
    """Call a Steam Web API method with protobuf encoding (POST)."""
    url = f"https://api.steampowered.com/{service}/{method}/v1/"
    encoded = base64.b64encode(request_proto.SerializeToString()).decode('ascii')
    data = urllib.parse.urlencode({'input_protobuf_encoded': encoded}).encode()
    req = urllib.request.Request(url, data=data, method='POST')
    return urllib.request.urlopen(req, timeout=15).read()


def _steam_api_get(service, method, request_proto):
    """Call a Steam Web API method with protobuf encoding (GET)."""
    encoded = base64.b64encode(request_proto.SerializeToString()).decode('ascii')
    params = urllib.parse.urlencode({'input_protobuf_encoded': encoded})
    url = f"https://api.steampowered.com/{service}/{method}/v1/?{params}"
    req = urllib.request.Request(url, method='GET')
    return urllib.request.urlopen(req, timeout=15).read()


def get_rsa_key(username):
    """Get RSA public key for password encryption."""
    msg = auth_pb.CAuthentication_GetPasswordRSAPublicKey_Request()
    msg.account_name = username
    resp_data = _steam_api_get('IAuthenticationService', 'GetPasswordRSAPublicKey', msg)
    resp = auth_pb.CAuthentication_GetPasswordRSAPublicKey_Response()
    resp.ParseFromString(resp_data)
    return resp.publickey_mod, resp.publickey_exp, resp.timestamp


def rsa_encrypt(password, mod_hex, exp_hex):
    """RSA PKCS#1 v1.5 encrypt password."""
    mod = int(mod_hex, 16)
    exp = int(exp_hex, 16)
    key_size = (mod.bit_length() + 7) // 8

    pw_bytes = password.encode('utf-8')
    padding_len = key_size - len(pw_bytes) - 3
    padding = b''
    while len(padding) < padding_len:
        byte = os.urandom(1)
        if byte != b'\x00':
            padding += byte
    padded = b'\x00\x02' + padding + b'\x00' + pw_bytes

    plaintext_int = int.from_bytes(padded, 'big')
    encrypted_int = pow(plaintext_int, exp, mod)
    return base64.b64encode(encrypted_int.to_bytes(key_size, 'big')).decode('ascii')


def web_auth_begin(username, encrypted_password, timestamp):
    """Begin auth session via protobuf Web API."""
    msg = auth_pb.CAuthentication_BeginAuthSessionViaCredentials_Request()
    msg.device_friendly_name = socket.gethostname()
    msg.account_name = username
    msg.encrypted_password = encrypted_password
    msg.encryption_timestamp = timestamp
    msg.remember_login = True
    msg.platform_type = 1  # k_EAuthTokenPlatformType_SteamClient
    msg.persistence = 1    # k_ESessionPersistence_Persistent
    msg.website_id = 'Client'

    resp_data = _steam_api_post('IAuthenticationService', 'BeginAuthSessionViaCredentials', msg)
    resp = auth_pb.CAuthentication_BeginAuthSessionViaCredentials_Response()
    resp.ParseFromString(resp_data)
    return resp


def web_auth_update_2fa(client_id, steamid, code, code_type=3):
    """Submit 2FA code. code_type: 2=email, 3=totp."""
    msg = auth_pb.CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request()
    msg.client_id = client_id
    msg.steamid = steamid
    msg.code = code
    msg.code_type = code_type

    resp_data = _steam_api_post('IAuthenticationService', 'UpdateAuthSessionWithSteamGuardCode', msg)
    return resp_data  # Just needs to succeed


def web_auth_poll(client_id, request_id):
    """Poll auth session for tokens."""
    msg = auth_pb.CAuthentication_PollAuthSessionStatus_Request()
    msg.client_id = client_id
    msg.request_id = request_id

    resp_data = _steam_api_post('IAuthenticationService', 'PollAuthSessionStatus', msg)
    resp = auth_pb.CAuthentication_PollAuthSessionStatus_Response()
    resp.ParseFromString(resp_data)
    return resp


def refresh_access_token(refresh_token, steamid=''):
    """Get a new access_token from refresh_token.

    Uses the CM network (SteamClient) since the HTTP Web API requires
    specific platform_type and often returns AccessDenied.
    Falls back to using stored access_token if available.
    """
    # First try: use stored access_token if still valid
    session_file = DATA_DIR / "session.json"
    if session_file.exists():
        session = json.loads(session_file.read_text())
        stored_token = session.get('accessToken', '')
        if stored_token and not _is_token_expired(stored_token):
            return stored_token

    # Second try: generate via anonymous SteamClient connection
    try:
        client = SteamClient()
        client.anonymous_login()
        job_id = client.send_um('Authentication.GenerateAccessTokenForApp#1', {
            'refresh_token': refresh_token,
        })
        msg = client.wait_msg(job_id, timeout=15)
        client.logout()
        if msg and hasattr(msg.body, 'access_token') and msg.body.access_token:
            # Save for future use
            if session_file.exists():
                session = json.loads(session_file.read_text())
                session['accessToken'] = msg.body.access_token
                session_file.write_text(json.dumps(session))
            return msg.body.access_token
    except Exception as e:
        log(f"  CM token refresh failed: {e}")

    # Third try: use stored access_token even if "expired" (might still work)
    if session_file.exists():
        session = json.loads(session_file.read_text())
        stored_token = session.get('accessToken', '')
        if stored_token:
            return stored_token

    return ''


def _is_token_expired(token):
    """Check if a JWT token is expired."""
    try:
        parts = token.split('.')
        if len(parts) < 2:
            return True
        payload = parts[1]
        payload += '=' * (4 - len(payload) % 4)
        payload = payload.replace('-', '+').replace('_', '/')
        data = json.loads(base64.b64decode(payload))
        return time.time() > data.get('exp', 0) - 60
    except Exception:
        return True


# ─── SteamClient with access_token login ──────────────────────────────────────

def login_with_token(username, refresh_token):
    """Login to Steam CM servers using a refresh_token.

    The refresh_token goes in the CMsgClientLogon.access_token field
    (despite the name — Steam uses the refresh JWT for CM auth).
    """
    from steam.utils import ip4_to_int

    client = SteamClient()
    client.set_credential_location(str(DATA_DIR))

    eresult = client._pre_login()
    if eresult != EResult.OK:
        return None, eresult

    client.username = username

    message = MsgProtoClass(EMsg.ClientLogon)
    message.header.steamid = SteamID(type='Individual', universe='Public')
    message.body.protocol_version = 65580
    message.body.client_package_version = 1561159470
    message.body.client_os_type = EOSType.Windows10
    message.body.client_language = "english"
    message.body.should_remember_password = True
    message.body.supports_rate_limit_response = True
    message.body.chat_mode = 2
    message.body.obfuscated_private_ip.v4 = ip4_to_int(client.connection.local_address) ^ 0xF00DBAAD
    message.body.account_name = username
    message.body.access_token = refresh_token  # refresh JWT goes here

    sentry = client.get_sentry(username)
    if sentry is None:
        message.body.eresult_sentryfile = EResult.FileNotFound
    else:
        message.body.eresult_sentryfile = EResult.OK
        message.body.sha_sentryfile = hashlib.sha1(sentry).digest()

    client.send(message)
    resp = client.wait_msg(EMsg.ClientLogOnResponse, timeout=30)

    if resp and resp.body.eresult == EResult.OK:
        client.sleep(0.5)
        return client, EResult.OK
    else:
        eresult = EResult(resp.body.eresult) if resp else EResult.Fail
        return None, eresult


def connect_with_token(refresh_token, username=''):
    """Connect to Steam using a stored refresh_token.

    The refresh_token is used directly in CMsgClientLogon.access_token
    to authenticate with Steam CM servers. No separate access_token
    generation needed.
    """
    # Get username from session file or JWT
    if not username:
        session_file = DATA_DIR / "session.json"
        if session_file.exists():
            session = json.loads(session_file.read_text())
            username = session.get('accountName', '')

    if not username:
        username = _extract_from_jwt(refresh_token, 'sub') or ''

    if not username:
        return None, "No username available"

    client, eresult = login_with_token(username, refresh_token)
    if client:
        return client, None
    else:
        return None, f"Login failed: {eresult}"


def _extract_from_jwt(token, field):
    """Extract a field from JWT payload."""
    try:
        parts = token.split('.')
        if len(parts) < 2:
            return None
        payload = parts[1]
        # Pad base64
        payload += '=' * (4 - len(payload) % 4)
        payload = payload.replace('-', '+').replace('_', '/')
        data = json.loads(base64.b64decode(payload))
        return str(data.get(field, ''))
    except Exception:
        return None


# ─── Cloud Operations ─────────────────────────────────────────────────────────

def cloud_list(client, appid):
    """List all cloud files for an app."""
    job_id = client.send_um('Cloud.EnumerateUserFiles#1', {
        'appid': appid,
        'extended_details': True,
    })

    files = []
    total_files, n_files = None, 0

    while total_files != n_files:
        msg = client.wait_msg(job_id, timeout=15)
        if not msg:
            return None, "Timeout listing cloud files"
        if msg.header.eresult != EResult.OK:
            return None, f"Error: {EResult(msg.header.eresult)}"
        total_files = msg.body.total_files
        n_files += len(msg.body.files)
        files.extend(msg.body.files)

    result = []
    for f in files:
        url = ''
        for attr in ['raw_file_url', 'download_url', 'url']:
            if hasattr(f, attr) and getattr(f, attr):
                url = getattr(f, attr)
                break
        result.append({
            'filename': f.filename,
            'size': f.file_size,
            'sha': (f.file_sha.hex() if isinstance(f.file_sha, bytes) else f.file_sha) if hasattr(f, 'file_sha') and f.file_sha else '',
            'url': url,
        })

    return result, None


def cloud_download_files(client, files, appid, output_dir):
    """Download cloud files to a directory."""
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    downloaded = 0

    for f in files:
        if f['size'] <= 0 or not f['url']:
            continue

        dest = out / f['filename']
        dest.parent.mkdir(parents=True, exist_ok=True)

        try:
            urllib.request.urlretrieve(f['url'], str(dest))
            downloaded += 1
            log(f"  Downloaded: {f['filename']} ({dest.stat().st_size} bytes)")
        except Exception as e:
            log(f"  Failed: {f['filename']}: {e}")

    return downloaded


def cloud_upload_file(client, appid, local_path, cloud_name):
    """Upload/overwrite a single file in Steam Cloud."""
    path = Path(local_path)
    if not path.exists():
        return False, f"File not found: {local_path}"

    data = path.read_bytes()
    file_size = len(data)
    file_sha = hashlib.sha1(data).digest()
    machine_name = socket.gethostname()

    # Step 1: Begin upload batch
    job_id = client.send_um('Cloud.BeginAppUploadBatch#1', {
        'appid': appid,
        'machine_name': machine_name,
        'files_to_upload': [cloud_name],
        'files_to_delete': [],
        'client_id': 0,
        'app_build_id': 0,
    })

    msg = client.wait_msg(job_id, timeout=15)
    if not msg or msg.header.eresult != EResult.OK:
        return False, f"BeginBatch: {EResult(msg.header.eresult) if msg else 'timeout'}"

    batch_id = msg.body.batch_id

    # Step 2: Begin file upload
    job_id = client.send_um('Cloud.ClientBeginFileUpload#1', {
        'appid': appid,
        'file_size': file_size,
        'raw_file_size': file_size,
        'file_sha': file_sha,
        'time_stamp': int(time.time()),
        'filename': cloud_name,
        'platforms_to_sync': 0xFFFFFFFF,
        'cell_id': 0,
        'can_encrypt': False,
        'is_shared_file': False,
        'upload_batch_id': batch_id,
    })

    msg = client.wait_msg(job_id, timeout=15)
    if not msg:
        return False, "ClientBeginFileUpload timeout"

    if msg.header.eresult == EResult.DuplicateRequest:
        # Same content already exists
        _complete_batch(client, appid, batch_id)
        return True, None

    if msg.header.eresult != EResult.OK:
        _complete_batch(client, appid, batch_id)
        return False, f"ClientBeginFileUpload: {EResult(msg.header.eresult)}"

    # Step 3: HTTP PUT blocks
    all_ok = True
    for block in msg.body.block_requests:
        url = block.url_host + block.url_path
        if not url.startswith('http'):
            url = 'https://' + url

        block_data = data[block.block_offset:block.block_offset + block.block_length]
        headers = {hdr.name: hdr.value for hdr in block.request_headers}
        req = urllib.request.Request(url, data=block_data, method='PUT', headers=headers)
        try:
            urllib.request.urlopen(req)
        except Exception as e:
            log(f"  HTTP PUT failed: {e}")
            all_ok = False

    # Step 4: Commit
    job_id = client.send_um('Cloud.ClientCommitFileUpload#1', {
        'transfer_succeeded': all_ok,
        'appid': appid,
        'file_sha': file_sha,
        'filename': cloud_name,
    })
    msg = client.wait_msg(job_id, timeout=15)
    committed = False
    if msg and msg.header.eresult == EResult.OK:
        committed = msg.body.file_committed if hasattr(msg.body, 'file_committed') else False

    # Step 5: Complete batch
    _complete_batch(client, appid, batch_id)

    return committed or all_ok, None


def _complete_batch(client, appid, batch_id):
    job_id = client.send_um('Cloud.CompleteAppUploadBatchBlocking#1', {
        'appid': appid,
        'batch_id': batch_id,
        'batch_eresult': 1,
    })
    client.wait_msg(job_id, timeout=10)


# ─── Sync Operations ─────────────────────────────────────────────────────────

def sync_down(client, appid, bottle_path):
    """Download ALL cloud files and place in Wine prefix.

    Always overwrites local files — cloud is the source of truth before launch.
    Files with Auto-Cloud prefixes (%WinAppDataLocal% etc.) go to the
    corresponding Wine prefix directory. Other files go to Goldberg save dir.
    """
    files, err = cloud_list(client, appid)
    if err:
        return 0, err

    bottle = Path(bottle_path)
    downloaded = 0

    # Also collect prefixed paths for non-prefixed duplicates
    # e.g. if cloud has both "%WinAppDataLocal%CB4/.../file.sav" and "file.sav",
    # the prefixed version tells us where the non-prefixed one should also go
    autocloud_dirs = set()

    for f in files:
        if f['size'] <= 0:
            continue

        filename = f['filename']
        url = f['url']

        if not url:
            log(f"  No URL for {filename}, skipping")
            continue

        # Determine ALL destination paths for this file
        destinations = []

        # Check for Auto-Cloud prefix
        matched_prefix = False
        for prefix, root_val in [
            ('%WinAppDataLocal%', 3),
            ('%WinAppDataRoaming%', 4),
            ('%WinAppDataLocalLow%', 5),
            ('%WinSavedGames%', 6),
            ('%WinMyDocuments%', 1),
        ]:
            if filename.startswith(prefix):
                rel = filename[len(prefix):]
                dest = bottle / ROOT_MAP[root_val] / rel
                destinations.append(dest)
                autocloud_dirs.add(dest.parent)
                matched_prefix = True
                break

        if not matched_prefix:
            # Non-prefixed file → Goldberg save dir
            goldberg_dest = (bottle / "drive_c/users/crossover/AppData/Roaming"
                             / "Goldberg SteamEmu Saves" / str(appid) / "remote" / filename)
            destinations.append(goldberg_dest)

            # Also check if this filename matches any Auto-Cloud save directory
            # (e.g. "76561199203490348Slot0Save.sav" should also go where the
            # prefixed version lives)
            for adir in autocloud_dirs:
                candidate = adir / Path(filename).name
                if candidate not in destinations:
                    destinations.append(candidate)

        # Download to a temp file first, then copy to all destinations
        import tempfile
        try:
            with tempfile.NamedTemporaryFile(delete=False, dir=str(bottle)) as tmp:
                tmp_path = tmp.name
            urllib.request.urlretrieve(url, tmp_path)

            for dest in destinations:
                dest.parent.mkdir(parents=True, exist_ok=True)
                # Always overwrite — cloud is source of truth
                import shutil
                shutil.copy2(tmp_path, str(dest))
                log(f"  Synced: {filename} → {dest.relative_to(bottle)}")

            os.unlink(tmp_path)
            downloaded += 1
        except Exception as e:
            log(f"  Failed: {filename}: {e}")
            try:
                os.unlink(tmp_path)
            except Exception:
                pass

    return downloaded, None


def sync_up(client, appid, bottle_path):
    """Collect saves from Wine prefix and upload to cloud."""
    # First get current cloud file list
    files, err = cloud_list(client, appid)
    if err:
        return 0, err

    bottle = Path(bottle_path)
    uploaded = 0

    # Build map of cloud filenames → file info
    cloud_map = {f['filename']: f for f in files}

    # Scan Wine prefix for modified save files
    for root_val, subpath in ROOT_MAP.items():
        scan_dir = bottle / subpath
        if not scan_dir.exists():
            continue

        for local_file in scan_dir.rglob('*'):
            if not local_file.is_file():
                continue

            # Skip non-save files
            name_lower = local_file.name.lower()
            if not any(name_lower.endswith(ext) for ext in
                       ['.sav', '.save', '.savegame', '.dat', '.cfg', '.ini', '.txt']):
                continue

            rel_path = str(local_file.relative_to(scan_dir))

            # Find matching cloud filename
            cloud_name = None
            # Check with Auto-Cloud prefix
            prefix_map = {3: '%WinAppDataLocal%', 4: '%WinAppDataRoaming%',
                          5: '%WinAppDataLocalLow%', 6: '%WinSavedGames%',
                          1: '%WinMyDocuments%', 2: '%WinMyDocuments%'}
            prefix = prefix_map.get(root_val, '')
            if prefix:
                candidate = prefix + rel_path
                if candidate in cloud_map:
                    cloud_name = candidate

            # Also check without prefix
            if not cloud_name and rel_path in cloud_map:
                cloud_name = rel_path

            if not cloud_name:
                continue  # Not a known cloud file

            # Check if local is newer (compare SHA)
            local_sha = hashlib.sha1(local_file.read_bytes()).hexdigest()
            cloud_sha = cloud_map[cloud_name].get('sha', '')
            if local_sha == cloud_sha:
                log(f"  Unchanged: {cloud_name}")
                continue

            # Upload
            ok, upload_err = cloud_upload_file(client, appid, str(local_file), cloud_name)
            if ok:
                uploaded += 1
                log(f"  Uploaded: {cloud_name}")
            else:
                log(f"  Upload failed: {cloud_name}: {upload_err}")

    return uploaded, None


# ─── Commands ─────────────────────────────────────────────────────────────────

def cmd_login(username, password, twofa=None):
    """Login via Web API auth flow, get refresh token."""
    try:
        # Step 1: Get RSA key
        log("  Getting RSA key...")
        mod, exp, timestamp = get_rsa_key(username)

        # Step 2: Encrypt password
        encrypted = rsa_encrypt(password, mod, exp)

        # Step 3: Begin auth session
        log("  Beginning auth session...")
        auth = web_auth_begin(username, encrypted, timestamp)

        client_id = auth.client_id
        request_id = auth.request_id
        steamid = str(auth.steamid)

        if not client_id:
            output({"success": False, "error": "Auth begin failed"})
            return 1

        log(f"  Auth started, steamid={steamid}, client_id={client_id}")

        # Step 4: Submit 2FA if needed
        needs_2fa = any(c.confirmation_type == 3 for c in auth.allowed_confirmations)
        needs_email = any(c.confirmation_type == 2 for c in auth.allowed_confirmations)

        if needs_2fa and twofa:
            log("  Submitting 2FA code...")
            web_auth_update_2fa(client_id, int(steamid), twofa, code_type=3)
        elif needs_email and twofa:
            log("  Submitting email code...")
            web_auth_update_2fa(client_id, int(steamid), twofa, code_type=2)
        elif needs_2fa or needs_email:
            output({"success": False, "error": "2FA code required", "needs_2fa": needs_2fa, "needs_email": needs_email})
            return 1

        # Step 5: Poll for tokens
        log("  Polling for tokens...")
        tokens = None
        for i in range(30):
            time.sleep(1)
            poll = web_auth_poll(client_id, request_id)
            if poll.refresh_token:
                tokens = poll
                break
            log(f"  Poll attempt {i+1}...")

        if not tokens or not tokens.refresh_token:
            output({"success": False, "error": "Auth polling timed out"})
            return 1

        refresh_token = tokens.refresh_token
        access_token = tokens.access_token
        account_name = tokens.account_name or username

        log(f"  Login success! account={account_name}")

        # Save session (including access_token for immediate reuse)
        session = {
            'steamID64': steamid,
            'accountName': account_name,
            'refreshToken': refresh_token,
            'accessToken': access_token,
        }
        (DATA_DIR / "session.json").write_text(json.dumps(session))

        output({
            "success": True,
            "steamID64": steamid,
            "accountName": account_name,
            "refreshToken": refresh_token,
            "accessToken": access_token,
        })
        return 0

    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode('utf-8', errors='replace') if hasattr(e, 'read') else str(e)
        except Exception:
            body = str(e)
        if e.code == 429:
            output({"success": False, "error": "Rate limited. Please wait a few minutes and try again."})
        else:
            output({"success": False, "error": f"HTTP {e.code}", "detail": body})
        return 1
    except Exception as e:
        import traceback
        traceback.print_exc(file=sys.stderr)
        output({"success": False, "error": str(e)})
        return 1


def cmd_token_login(refresh_token):
    """Verify refresh token is valid by generating access token."""
    try:
        access_token = refresh_access_token(refresh_token)
        if access_token:
            steamid = _extract_from_jwt(refresh_token, 'sub') or ''
            output({"success": True, "steamID64": steamid, "accessToken": access_token})
            return 0
        else:
            output({"success": False, "error": "Token refresh failed"})
            return 1
    except Exception as e:
        output({"success": False, "error": str(e)})
        return 1


def cmd_list(appid, refresh_token):
    """List cloud files."""
    client, err = connect_with_token(refresh_token)
    if err:
        output({"error": err, "count": 0})
        return 1

    try:
        files, err = cloud_list(client, appid)
        if err:
            output({"error": err, "count": 0})
            return 1

        output({
            "files": [{"filename": f['filename'], "size": f['size']} for f in files],
            "count": len(files),
        })
        return 0
    finally:
        client.logout()


def cmd_download(appid, output_dir, refresh_token):
    """Download all cloud files."""
    client, err = connect_with_token(refresh_token)
    if err:
        output({"error": err, "downloaded": 0})
        return 1

    try:
        files, err = cloud_list(client, appid)
        if err:
            output({"error": err, "downloaded": 0})
            return 1

        count = cloud_download_files(client, files, appid, output_dir)
        output({"downloaded": count})
        return 0
    finally:
        client.logout()


def cmd_upload(appid, local_file, cloud_name, refresh_token):
    """Upload a file to Steam Cloud."""
    client, err = connect_with_token(refresh_token)
    if err:
        output({"error": err, "success": False})
        return 1

    try:
        ok, err = cloud_upload_file(client, appid, local_file, cloud_name)
        output({"success": ok, "error": err})
        return 0 if ok else 1
    finally:
        client.logout()


def cmd_sync_down(appid, bottle_path, refresh_token):
    """Download cloud files and place in Wine prefix."""
    client, err = connect_with_token(refresh_token)
    if err:
        output({"error": err, "downloaded": 0})
        return 1

    try:
        count, err = sync_down(client, appid, bottle_path)
        output({"downloaded": count, "error": err})
        return 0
    finally:
        client.logout()


def cmd_sync_up(appid, bottle_path, refresh_token):
    """Upload saves from Wine prefix to Steam Cloud."""
    client, err = connect_with_token(refresh_token)
    if err:
        output({"error": err, "uploaded": 0})
        return 1

    try:
        count, err = sync_up(client, appid, bottle_path)
        output({"uploaded": count, "error": err})
        return 0
    finally:
        client.logout()


def cmd_licenses(refresh_token):
    """Fetch all owned app IDs from Steam licenses via PICS."""
    client, err = connect_with_token(refresh_token)
    if err:
        output({"error": err, "appids": []})
        return 1

    try:
        # Wait for license list to arrive (sent automatically on login)
        time.sleep(2)
        pkg_ids = list(client.licenses.keys())
        log(f"  Found {len(pkg_ids)} license packages")

        if not pkg_ids:
            output({"appids": [], "count": 0})
            return 0

        # Build package requests with access tokens from licenses
        pkg_requests = []
        for pid in pkg_ids:
            lic = client.licenses[pid]
            pkg_requests.append({
                'packageid': pid,
                'access_token': lic.access_token if hasattr(lic, 'access_token') else 0,
            })

        # Use get_product_info to resolve packages → app IDs
        result = client.get_product_info(packages=pkg_requests, auto_access_tokens=False, timeout=30)

        app_ids = set()
        if result:
            for pid, info in result.get('packages', {}).items():
                appids_section = info.get('appids', {})
                if isinstance(appids_section, dict):
                    for _, aid in appids_section.items():
                        try:
                            app_ids.add(int(aid))
                        except (ValueError, TypeError):
                            pass

        app_list = sorted(app_ids)
        log(f"  Resolved {len(app_list)} app IDs from {len(pkg_ids)} packages")
        output({"appids": app_list, "count": len(app_list)})
        return 0
    finally:
        client.logout()


def cmd_download_game(appid, install_dir, refresh_token):
    """Download a game's files via Steam CDN."""
    client, err = connect_with_token(refresh_token)
    if err:
        output({"error": err, "success": False})
        return 1

    try:
        time.sleep(2)
        from steam.client.cdn import CDNClient

        cdn = CDNClient(client)

        log(f"  Getting manifests for app {appid}...")

        # Monkey-patch to handle new manifest format (dict with 'gid' key)
        _orig_get_manifests = cdn.get_manifests.__func__

        def _patched_get_manifests(self, app_id, branch='public', password=None,
                                   filter_func=None, decrypt=True):
            # Get depot info and fix manifest_gid format before calling original
            depot_info = self.get_app_depot_info(app_id)
            if depot_info:
                for depot_id, info in depot_info.items():
                    if isinstance(info, dict) and 'manifests' in info:
                        manifests = info['manifests']
                        for branch_name, val in manifests.items():
                            if isinstance(val, dict) and 'gid' in val:
                                manifests[branch_name] = val['gid']
            return _orig_get_manifests(self, app_id, branch, password,
                                       filter_func, decrypt)

        import types
        cdn.get_manifests = types.MethodType(_patched_get_manifests, cdn)

        manifests = cdn.get_manifests(appid)

        if not manifests:
            output({"error": "No manifests found", "success": False})
            return 1

        # Count total files and size
        total_files = 0
        total_size = 0
        all_files = []
        for manifest in manifests:
            for f in manifest.iter_files():
                total_files += 1
                total_size += f.size
                all_files.append(f)

        log(f"  {total_files} files, {total_size / 1024 / 1024:.1f} MB total")

        # Download files
        dest = Path(install_dir)
        dest.mkdir(parents=True, exist_ok=True)
        downloaded = 0

        for f in all_files:
            if f.is_directory:
                (dest / f.filename).mkdir(parents=True, exist_ok=True)
                continue

            file_path = dest / f.filename
            file_path.parent.mkdir(parents=True, exist_ok=True)

            try:
                with open(str(file_path), 'wb') as fh:
                    for chunk in f:
                        fh.write(chunk)
                downloaded += 1

                # Progress output for Swift to parse
                pct = (downloaded / total_files) * 100
                log(f"  [{pct:.1f}%] {f.filename} ({f.size} bytes)")

                # Flush progress as JSON line to stdout for real-time parsing
                progress_msg = json.dumps({
                    "progress": round(pct, 1),
                    "file": f.filename,
                    "downloaded": downloaded,
                    "total": total_files
                })
                print(progress_msg, flush=True)

            except Exception as e:
                log(f"  Failed: {f.filename}: {e}")

        output({
            "success": True,
            "downloaded": downloaded,
            "total_files": total_files,
            "total_size": total_size
        })
        return 0

    except Exception as e:
        import traceback
        traceback.print_exc(file=sys.stderr)
        output({"error": str(e), "success": False})
        return 1
    finally:
        client.logout()


def cmd_check():
    """Check if we can connect to Steam (always true, no Steam.app needed)."""
    output({"running": True})
    return 0


def cmd_whoami(refresh_token):
    """Get current user info from token."""
    try:
        steamid = _extract_from_jwt(refresh_token, 'sub') or ''
        session_file = DATA_DIR / "session.json"
        name = ''
        if session_file.exists():
            session = json.loads(session_file.read_text())
            name = session.get('accountName', '')
        output({"steamID64": steamid, "personaName": name})
        return 0
    except Exception as e:
        output({"error": str(e)})
        return 1


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1

    cmd = sys.argv[1]

    if cmd == "login":
        if len(sys.argv) < 4:
            print("Usage: jacksteam.py login <user> <pass> [<2fa>]", file=sys.stderr)
            return 1
        return cmd_login(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)

    elif cmd == "token-login":
        if len(sys.argv) < 3:
            print("Usage: jacksteam.py token-login <refresh_token>", file=sys.stderr)
            return 1
        return cmd_token_login(sys.argv[2])

    elif cmd == "licenses":
        if len(sys.argv) < 3:
            print("Usage: jacksteam.py licenses <refresh_token>", file=sys.stderr)
            return 1
        return cmd_licenses(sys.argv[2])

    elif cmd == "check":
        return cmd_check()

    elif cmd == "whoami":
        if len(sys.argv) < 3:
            print("Usage: jacksteam.py whoami <refresh_token>", file=sys.stderr)
            return 1
        return cmd_whoami(sys.argv[2])

    elif cmd == "list":
        if len(sys.argv) < 4:
            print("Usage: jacksteam.py list <appid> <refresh_token>", file=sys.stderr)
            return 1
        return cmd_list(int(sys.argv[2]), sys.argv[3])

    elif cmd == "download":
        if len(sys.argv) < 5:
            print("Usage: jacksteam.py download <appid> <dir> <refresh_token>", file=sys.stderr)
            return 1
        return cmd_download(int(sys.argv[2]), sys.argv[3], sys.argv[4])

    elif cmd == "upload":
        if len(sys.argv) < 6:
            print("Usage: jacksteam.py upload <appid> <file> <name> <refresh_token>", file=sys.stderr)
            return 1
        return cmd_upload(int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5])

    elif cmd == "sync-down":
        if len(sys.argv) < 5:
            print("Usage: jacksteam.py sync-down <appid> <bottle> <refresh_token>", file=sys.stderr)
            return 1
        return cmd_sync_down(int(sys.argv[2]), sys.argv[3], sys.argv[4])

    elif cmd == "sync-up":
        if len(sys.argv) < 5:
            print("Usage: jacksteam.py sync-up <appid> <bottle> <refresh_token>", file=sys.stderr)
            return 1
        return cmd_sync_up(int(sys.argv[2]), sys.argv[3], sys.argv[4])

    elif cmd == "download-game":
        if len(sys.argv) < 5:
            print("Usage: jacksteam.py download-game <appid> <install_dir> <refresh_token>", file=sys.stderr)
            return 1
        return cmd_download_game(int(sys.argv[2]), sys.argv[3], sys.argv[4])

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
