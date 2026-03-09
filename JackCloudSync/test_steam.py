#!/usr/bin/env python3
"""
Test all Steam operations: login, list cloud, download, upload.
Run from terminal: python3 test_steam.py <username> <password> <2fa_code>
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
from pathlib import Path
from steam.client import SteamClient, EResult, EMsg, MsgProto
from steam.enums import EPersonaState
from steam.exceptions import SteamError

DATA_DIR = Path.home() / "Library" / "Application Support" / "com.isaacmarovitz.Jack" / "SteamSession"
DATA_DIR.mkdir(parents=True, exist_ok=True)

def test_login(username, password, twofa):
    """Test login and save session."""
    print("\n=== TEST: Login ===")

    client = SteamClient()
    client.set_credential_location(str(DATA_DIR))

    login_key_received = [False]

    @client.on(client.EVENT_NEW_LOGIN_KEY)
    def on_new_key():
        login_key_received[0] = True
        key_path = DATA_DIR / f"{username}.key"
        key_path.write_text(client.login_key)
        print(f"  [OK] Login key saved to {key_path}")

    print(f"  Logging in as {username}...")
    result = client.login(username, password, two_factor_code=twofa)

    if result != EResult.OK:
        print(f"  [FAIL] Login failed: {result}")
        return None

    print(f"  [OK] Login successful! SteamID: {client.steam_id}")
    (DATA_DIR / "lastuser").write_text(username)

    # Wait for login key
    print("  Waiting for login key (up to 30s)...")
    for i in range(60):
        client.sleep(0.5)
        if login_key_received[0]:
            break

    if not login_key_received[0]:
        print("  [WARN] Login key not received, session won't persist")

    return client


def test_relogin(username):
    """Test re-login with saved key."""
    print("\n=== TEST: Re-login with saved key ===")

    key_path = DATA_DIR / f"{username}.key"
    if not key_path.exists():
        print("  [SKIP] No saved key")
        return None

    client = SteamClient()
    client.set_credential_location(str(DATA_DIR))
    client.username = username
    client.login_key = key_path.read_text()

    @client.on(client.EVENT_NEW_LOGIN_KEY)
    def on_new_key():
        key_path.write_text(client.login_key)
        print(f"  [OK] Login key rotated and saved")

    result = client.relogin()

    if result == EResult.OK:
        print(f"  [OK] Re-login successful! SteamID: {client.steam_id}")
        return client
    else:
        print(f"  [FAIL] Re-login failed: {result}")
        key_path.unlink(missing_ok=True)
        return None


def test_cloud_list(client, appid):
    """Test listing cloud files."""
    print(f"\n=== TEST: Cloud List (appid={appid}) ===")

    job_id = client.send_um('Cloud.EnumerateUserFiles#1', {
        'appid': appid,
        'extended_details': True,
    })

    files = []
    total_files, n_files = None, 0

    while total_files != n_files:
        msg = client.wait_msg(job_id, timeout=15)
        if not msg:
            print("  [FAIL] Timeout")
            return []
        if msg.header.eresult != EResult.OK:
            print(f"  [FAIL] Error: {EResult(msg.header.eresult)}")
            return []
        total_files = msg.body.total_files
        n_files += len(msg.body.files)
        files.extend(msg.body.files)

    print(f"  [OK] Found {len(files)} files:")
    for f in files:
        url_status = "has URL" if (hasattr(f, 'raw_file_url') and f.raw_file_url) else "no URL"
        print(f"    - {f.filename} ({f.file_size} bytes) [{url_status}]")

    return files


def test_cloud_download(client, files, appid, output_dir):
    """Test downloading cloud files."""
    print(f"\n=== TEST: Cloud Download (appid={appid}) ===")

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    downloaded = 0
    for f in files:
        if f.file_size <= 0:
            continue

        url = None
        for attr in ['raw_file_url', 'download_url', 'url']:
            if hasattr(f, attr) and getattr(f, attr):
                url = getattr(f, attr)
                break

        if not url:
            # Try to get download URL via explicit request
            print(f"  No direct URL for {f.filename}, trying ClientFileList...")
            continue

        import urllib.request
        dest = out / f.filename
        dest.parent.mkdir(parents=True, exist_ok=True)

        try:
            urllib.request.urlretrieve(url, str(dest))
            downloaded += 1
            actual_size = dest.stat().st_size
            print(f"  [OK] {f.filename} ({actual_size} bytes)")
        except Exception as e:
            print(f"  [FAIL] {f.filename}: {e}")

    if downloaded == 0 and files:
        # Try alternate download method: ClientFileList
        print("  Trying ClientFileList method...")
        job_id = client.send_um('Cloud.ClientFileList#1', {
            'appid': appid,
        })
        msg = client.wait_msg(job_id, timeout=15)
        if msg and msg.header.eresult == EResult.OK:
            for f2 in msg.body.files:
                url = None
                for attr in ['raw_file_url', 'download_url', 'url']:
                    if hasattr(f2, attr) and getattr(f2, attr):
                        url = getattr(f2, attr)
                        break
                if url and f2.file_size > 0:
                    import urllib.request
                    dest = out / f2.filename
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        urllib.request.urlretrieve(url, str(dest))
                        downloaded += 1
                        print(f"  [OK] {f2.filename} ({dest.stat().st_size} bytes)")
                    except Exception as e:
                        print(f"  [FAIL] {f2.filename}: {e}")
        else:
            print(f"  [FAIL] ClientFileList failed: {msg.header.eresult if msg else 'timeout'}")

    print(f"  Total downloaded: {downloaded}")
    return downloaded


def test_cloud_quota(client, appid):
    """Check cloud quota for an app."""
    print(f"\n=== TEST: Cloud Quota (appid={appid}) ===")

    job_id = client.send_um('Cloud.ClientGetAppQuotaUsage#1', {
        'appid': appid,
    })

    msg = client.wait_msg(job_id, timeout=15)
    if not msg:
        print("  [FAIL] Timeout")
        return None

    if msg.header.eresult != EResult.OK:
        print(f"  [FAIL] Error: {EResult(msg.header.eresult)}")
        return None

    body = msg.body
    print(f"  Files: {body.existing_files} / {body.max_num_files}")
    print(f"  Bytes: {body.existing_bytes} / {body.max_num_bytes}")
    return body


def test_cloud_delete(client, appid, cloud_name):
    """Delete a file from Steam Cloud."""
    print(f"\n=== TEST: Cloud Delete (appid={appid}, {cloud_name}) ===")

    job_id = client.send_um('Cloud.Delete#1', {
        'filename': cloud_name,
        'appid': appid,
    })

    msg = client.wait_msg(job_id, timeout=15)
    if not msg:
        print("  [FAIL] Timeout")
        return False

    if msg.header.eresult != EResult.OK:
        print(f"  [FAIL] Delete error: {EResult(msg.header.eresult)}")
        return False

    print(f"  [OK] Deleted {cloud_name}")
    return True


def test_cloud_upload_with_delete(client, appid, local_file, cloud_name, delete_files=None):
    """Upload with files_to_delete in the batch to free quota."""
    print(f"\n=== TEST: Cloud Upload+Delete (appid={appid}, {cloud_name}) ===")

    path = Path(local_file)
    data = path.read_bytes()
    file_size = len(data)
    file_sha = hashlib.sha1(data).digest()

    print(f"  File: {cloud_name} ({file_size} bytes, sha1={file_sha.hex()})")
    if delete_files:
        print(f"  Deleting in batch: {delete_files}")

    import socket
    machine_name = socket.gethostname()

    # Begin batch with both upload and delete
    job_id = client.send_um('Cloud.BeginAppUploadBatch#1', {
        'appid': appid,
        'machine_name': machine_name,
        'files_to_upload': [cloud_name],
        'files_to_delete': delete_files or [],
        'client_id': 0,
        'app_build_id': 0,
    })

    msg = client.wait_msg(job_id, timeout=15)
    if not msg or msg.header.eresult != EResult.OK:
        print(f"  [FAIL] BeginBatch: {EResult(msg.header.eresult) if msg else 'timeout'}")
        return False

    batch_id = msg.body.batch_id
    print(f"  [OK] Batch ID: {batch_id}")

    # Delete files first
    if delete_files:
        for df in delete_files:
            job_id = client.send_um('Cloud.ClientDeleteFile#1', {
                'appid': appid,
                'filename': df,
            })
            msg = client.wait_msg(job_id, timeout=10)
            if msg and msg.header.eresult == EResult.OK:
                print(f"  [OK] Deleted: {df}")
            else:
                print(f"  [WARN] Delete {df}: {EResult(msg.header.eresult) if msg else 'timeout'}")

    # Now upload
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
        print("  [FAIL] ClientBeginFileUpload timeout")
        return False

    if msg.header.eresult != EResult.OK:
        if msg.header.eresult == EResult.DuplicateRequest:
            print("  [OK] File already exists with same content")
        else:
            print(f"  [FAIL] ClientBeginFileUpload: {EResult(msg.header.eresult)}")
        # Complete batch either way
        job_id = client.send_um('Cloud.CompleteAppUploadBatchBlocking#1', {
            'appid': appid, 'batch_id': batch_id, 'batch_eresult': 1,
        })
        client.wait_msg(job_id, timeout=10)
        return msg.header.eresult == EResult.DuplicateRequest

    print(f"  [OK] Got {len(msg.body.block_requests)} upload block(s)")

    # HTTP PUT blocks
    import urllib.request
    all_ok = True
    for block in msg.body.block_requests:
        url = block.url_host + block.url_path
        if not url.startswith('http'):
            url = 'https://' + url
        block_data = data[block.block_offset:block.block_offset + block.block_length]
        headers = {hdr.name: hdr.value for hdr in block.request_headers}
        req = urllib.request.Request(url, data=block_data, method='PUT', headers=headers)
        try:
            resp = urllib.request.urlopen(req)
            print(f"  [OK] HTTP PUT: {resp.status}")
        except Exception as e:
            print(f"  [FAIL] HTTP PUT: {e}")
            all_ok = False

    # Commit
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
        print(f"  [OK] Committed: {committed}")
    else:
        print(f"  [FAIL] Commit: {EResult(msg.header.eresult) if msg else 'timeout'}")

    # Complete batch
    job_id = client.send_um('Cloud.CompleteAppUploadBatchBlocking#1', {
        'appid': appid, 'batch_id': batch_id, 'batch_eresult': 1,
    })
    msg = client.wait_msg(job_id, timeout=10)
    if msg and msg.header.eresult == EResult.OK:
        print("  [OK] Batch completed")
    else:
        print(f"  [WARN] Batch: {EResult(msg.header.eresult) if msg else 'timeout'}")

    return committed


def test_cloud_upload(client, appid, local_file, cloud_name):
    """Test uploading a file to Steam Cloud using batch API."""
    print(f"\n=== TEST: Cloud Upload (appid={appid}, {cloud_name}) ===")

    path = Path(local_file)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"Jack cloud test {time.time()}")
        print(f"  Created test file: {path}")

    data = path.read_bytes()
    file_size = len(data)
    file_sha = hashlib.sha1(data).digest()

    print(f"  File: {cloud_name} ({file_size} bytes, sha1={file_sha.hex()})")

    import socket
    machine_name = socket.gethostname()

    # Step 1: Begin upload batch
    print("  Step 1: BeginAppUploadBatch...")
    job_id = client.send_um('Cloud.BeginAppUploadBatch#1', {
        'appid': appid,
        'machine_name': machine_name,
        'files_to_upload': [cloud_name],
        'files_to_delete': [],
        'client_id': 0,
        'app_build_id': 0,
    })

    msg = client.wait_msg(job_id, timeout=15)
    if not msg:
        print("  [FAIL] BeginAppUploadBatch timeout")
        return False

    if msg.header.eresult != EResult.OK:
        print(f"  [FAIL] BeginAppUploadBatch error: {EResult(msg.header.eresult)}")
        return False

    batch_id = msg.body.batch_id
    print(f"  [OK] Batch ID: {batch_id}")

    # Step 2: Begin file upload
    print("  Step 2: ClientBeginFileUpload...")
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
        print("  [FAIL] ClientBeginFileUpload timeout")
        return False

    if msg.header.eresult != EResult.OK:
        if msg.header.eresult == EResult.DuplicateRequest:
            print("  [OK] File already exists with same content, skipping upload")
            # Still need to complete the batch
            job_id = client.send_um('Cloud.CompleteAppUploadBatchBlocking#1', {
                'appid': appid,
                'batch_id': batch_id,
                'batch_eresult': 1,  # OK
            })
            client.wait_msg(job_id, timeout=10)
            return True
        print(f"  [FAIL] ClientBeginFileUpload error: {EResult(msg.header.eresult)}")
        return False

    print(f"  [OK] Got {len(msg.body.block_requests)} upload block(s)")

    # Step 3: HTTP PUT each block
    import urllib.request

    all_ok = True
    for block in msg.body.block_requests:
        url = block.url_host + block.url_path
        if not url.startswith('http'):
            url = 'https://' + url

        print(f"  Step 3: HTTP PUT to {block.url_host}...")

        block_data = data[block.block_offset:block.block_offset + block.block_length]

        headers = {}
        for hdr in block.request_headers:
            headers[hdr.name] = hdr.value

        req = urllib.request.Request(url, data=block_data, method='PUT', headers=headers)
        try:
            resp = urllib.request.urlopen(req)
            print(f"  [OK] HTTP PUT: {resp.status}")
        except Exception as e:
            print(f"  [FAIL] HTTP PUT: {e}")
            all_ok = False

    # Step 4: Commit file upload
    print("  Step 4: ClientCommitFileUpload...")
    job_id = client.send_um('Cloud.ClientCommitFileUpload#1', {
        'transfer_succeeded': all_ok,
        'appid': appid,
        'file_sha': file_sha,
        'filename': cloud_name,
    })

    msg = client.wait_msg(job_id, timeout=15)
    if not msg:
        print("  [FAIL] CommitFileUpload timeout")
        return False

    if msg.header.eresult != EResult.OK:
        print(f"  [FAIL] CommitFileUpload error: {EResult(msg.header.eresult)}")
        return False

    committed = msg.body.file_committed if hasattr(msg.body, 'file_committed') else False
    print(f"  [OK] File committed: {committed}")

    # Step 5: Complete upload batch
    print("  Step 5: CompleteAppUploadBatch...")
    job_id = client.send_um('Cloud.CompleteAppUploadBatchBlocking#1', {
        'appid': appid,
        'batch_id': batch_id,
        'batch_eresult': 1,  # EResult.OK
    })

    msg = client.wait_msg(job_id, timeout=15)
    if msg and msg.header.eresult == EResult.OK:
        print("  [OK] Batch completed")
    else:
        print(f"  [WARN] Batch completion: {EResult(msg.header.eresult) if msg else 'timeout'}")

    return committed


def main():
    if len(sys.argv) < 4:
        print("Usage: python3 test_steam.py <username> <password> <2fa_code>")
        return 1

    username = sys.argv[1]
    password = sys.argv[2]
    twofa = sys.argv[3]

    # Test 1: Login
    client = test_login(username, password, twofa)
    if not client:
        return 1

    try:
        # Test 2: Check cloud quotas
        test_cloud_quota(client, 268910)
        quota = test_cloud_quota(client, 1378990)

        # Test 3: List CB4 cloud files (1378990)
        cb4_files = test_cloud_list(client, 1378990)

        # Test 4: Download CB4 saves
        test_cloud_download(client, cb4_files, 1378990, "/tmp/jack_cloud_test/1378990")

        # Test 5: Delete jack_test.txt to free a quota slot, then upload replacement
        # Quota is 5/5 — we MUST delete first or replace in same batch
        print("\n=== TEST: Cloud Delete + Upload (free quota slot) ===")

        # Strategy A: Use files_to_delete in the batch to atomically replace
        test_file = "/tmp/jack_cloud_test/upload_test.txt"
        Path(test_file).parent.mkdir(parents=True, exist_ok=True)
        Path(test_file).write_text(f"Jack upload test {time.time()}\n")

        # Try overwriting jack_test.txt (already exists, so no quota change)
        print("  Strategy A: Overwrite existing jack_test.txt...")
        test_cloud_upload(client, 1378990, test_file, "jack_test.txt")

        # Strategy B: Delete old file in batch, upload new one
        print("\n  Strategy B: Delete jack_test.txt in batch, upload new file...")
        test_cloud_upload_with_delete(client, 1378990, test_file,
                                       "jack_upload_test.txt",
                                       delete_files=["jack_test.txt"])

        # Test 6: Verify by listing again
        print("\n=== TEST: Verify upload ===")
        cb4_files2 = test_cloud_list(client, 1378990)
        test_cloud_quota(client, 1378990)

    finally:
        client.logout()

    print("\n=== ALL TESTS COMPLETE ===")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
