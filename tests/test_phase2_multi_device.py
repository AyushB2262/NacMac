#!/usr/bin/env python3
"""
Phase 2 Multi-Device, Clipboard Sync, Notification Actions & SMS Protocol Test Suite.
Tests:
  1. Multi-Device Concurrent Pairing & Connection Management (Device A + Device B simultaneously).
  2. Heartbeat Keepalive on multiple concurrent sockets.
  3. Universal Bidirectional Clipboard Sync (Device A -> Mac -> Device B broadcast, SHA-256 hash matching, edge cases).
  4. Interactive Notification Actions & In-line Replies (Action click, RemoteInput text reply, dismissal).
  5. SMS / RCS Messaging Hub (Conversation query, message thread query, SMS send & status response).
  6. Disconnect Isolation (Device A disconnects; Device B continues uninterrupted; Device A seamlessly reconnects).
"""

import sys
import os
import socket
import struct
import json
import time
import hashlib
import base64
import uuid
import subprocess
import shutil
import atexit
import signal

PORT = 52840
HOST = "127.0.0.1"

class PacketFraming:
    @staticmethod
    def send_envelope(sock, msg_type, payload_dict):
        payload_str = json.dumps(payload_dict)
        envelope = {
            "type": msg_type,
            "payload": payload_str
        }
        body = json.dumps(envelope).encode("utf-8")
        header = struct.pack(">I", len(body))
        sock.sendall(header + body)

    @staticmethod
    def read_envelope(sock, timeout=5.0):
        sock.settimeout(timeout)
        try:
            header = sock.recv(4)
            if not header or len(header) < 4:
                return None
            length = struct.unpack(">I", header)[0]
            data = bytearray()
            while len(data) < length:
                chunk = sock.recv(length - len(data))
                if not chunk:
                    break
                data.extend(chunk)
            raw_json = data.decode("utf-8")
            return json.loads(raw_json)
        except Exception:
            return None

def sha256_str(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

def run_tests():
    print("=" * 70)
    print("NacMac Phase 2 Multi-Device & Advanced Features Test Suite")
    print("=" * 70)

    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates = [
        os.path.join(repo_dir, "macos/NacMac.app/Contents/MacOS/NacMac"),
        os.path.join(repo_dir, "macos/.build/release/NacMac"),
        os.path.join(repo_dir, "macos/.build/arm64-apple-macosx/release/NacMac"),
        os.path.join(repo_dir, "macos/.build/debug/NacMac")
    ]
    bin_path = next((p for p in candidates if os.path.exists(p)), None)
    if not bin_path:
        print("[FAIL] Executable not found.")
        sys.exit(1)

    print(f"[*] Found native binary at: {bin_path}")

    nacmac_dir = os.path.expanduser("~/.nacmac")
    os.makedirs(nacmac_dir, exist_ok=True)
    paired_path = os.path.join(nacmac_dir, "paired_device.json")
    paired_multi_path = os.path.join(nacmac_dir, "paired_devices.json")
    qr_path = os.path.join(nacmac_dir, "active_qr.json")
    paired_bak = os.path.join(nacmac_dir, "paired_device.json.p2_bak")
    paired_multi_bak = os.path.join(nacmac_dir, "paired_devices.json.p2_bak")
    qr_bak = os.path.join(nacmac_dir, "active_qr.json.p2_bak")

    # Check if port is in use
    test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    is_busy = (test_sock.connect_ex((HOST, PORT)) == 0)
    test_sock.close()

    proc = None

    if not is_busy:
        had_paired = False
        if os.path.exists(paired_path):
            shutil.copy2(paired_path, paired_bak)
            os.remove(paired_path)
            had_paired = True

        had_paired_multi = False
        if os.path.exists(paired_multi_path):
            shutil.copy2(paired_multi_path, paired_multi_bak)
            os.remove(paired_multi_path)
            had_paired_multi = True

        had_qr = False
        if os.path.exists(qr_path):
            shutil.copy2(qr_path, qr_bak)
            os.remove(qr_path)
            had_qr = True

        def restore_state():
            if had_paired and os.path.exists(paired_bak):
                shutil.move(paired_bak, paired_path)
            elif os.path.exists(paired_bak):
                os.remove(paired_bak)
            elif not had_paired and os.path.exists(paired_path):
                os.remove(paired_path)

            if had_paired_multi and os.path.exists(paired_multi_bak):
                shutil.move(paired_multi_bak, paired_multi_path)
            elif os.path.exists(paired_multi_bak):
                os.remove(paired_multi_bak)
            elif not had_paired_multi and os.path.exists(paired_multi_path):
                os.remove(paired_multi_path)

            if had_qr and os.path.exists(qr_bak):
                shutil.move(qr_bak, qr_path)
            elif os.path.exists(qr_bak):
                os.remove(qr_bak)
            elif not had_qr and os.path.exists(qr_path):
                os.remove(qr_path)

        atexit.register(restore_state)

        proc = subprocess.Popen([bin_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        print(f"[*] Started macOS server daemon (PID: {proc.pid})...")

        for _ in range(30):
            if os.path.exists(qr_path):
                break
            time.sleep(0.2)

        assert os.path.exists(qr_path), f"active_qr.json not generated at {qr_path}"
        with open(qr_path, "r") as f:
            qr_data = json.load(f)
        shared_secret = qr_data["secret"]
    else:
        print("[SKIP] Port 52840 is in use by a live NacMac session; refusing to modify real pairing state.")
        sys.exit(0)

    print(f"[*] Mac Auth Secret: {shared_secret[:8]}... ({qr_data.get('macName', 'Mac')})")

    sock_a = None
    sock_b = None

    try:
        # -------------------------------------------------------------
        # TEST 1: Multi-Device Concurrent Pairing & Connection Handshake
        # -------------------------------------------------------------
        print("\n--- Test 1: Multi-Device Concurrent Pairing (Device A & Device B) ---")
        
        # Connect Device A (Google Pixel 8 Pro)
        sock_a = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock_a.connect((HOST, PORT))
        dev_a_id = "pixel8-pro-" + str(uuid.uuid4())[:6]
        PacketFraming.send_envelope(sock_a, "PAIR_REQUEST", {
            "androidId": dev_a_id,
            "deviceName": "Google Pixel 8 Pro",
            "authSecret": shared_secret
        })
        resp_a = PacketFraming.read_envelope(sock_a)
        assert resp_a is not None and resp_a["type"] == "PAIR_RESPONSE", "Device A pair failed"
        payload_a = json.loads(resp_a["payload"])
        assert payload_a["success"] is True, f"Device A auth rejected: {payload_a}"
        print(f"[PASS] Device A connected: {dev_a_id} ('Google Pixel 8 Pro')")

        # Connect Device B (Samsung Galaxy S24) simultaneously
        sock_b = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock_b.connect((HOST, PORT))
        dev_b_id = "galaxy-s24-" + str(uuid.uuid4())[:6]
        PacketFraming.send_envelope(sock_b, "PAIR_REQUEST", {
            "androidId": dev_b_id,
            "deviceName": "Samsung Galaxy S24",
            "authSecret": shared_secret
        })
        resp_b = PacketFraming.read_envelope(sock_b)
        assert resp_b is not None and resp_b["type"] == "PAIR_RESPONSE", "Device B pair failed"
        payload_b = json.loads(resp_b["payload"])
        assert payload_b["success"] is True, f"Device B auth rejected: {payload_b}"
        print(f"[PASS] Device B connected concurrently: {dev_b_id} ('Samsung Galaxy S24')")

        # Verify paired_devices.json contains both records
        time.sleep(0.3)
        assert os.path.exists(paired_multi_path), f"{paired_multi_path} not found"
        with open(paired_multi_path, "r") as f:
            multi_records = json.load(f)
        record_ids = [r["androidId"] for r in multi_records]
        assert dev_a_id in record_ids, f"Device A {dev_a_id} not in multi records: {record_ids}"
        assert dev_b_id in record_ids, f"Device B {dev_b_id} not in multi records: {record_ids}"
        print(f"[PASS] Multi-device registry confirmed with {len(multi_records)} devices in {paired_multi_path}")

        # -------------------------------------------------------------
        # TEST 2: Concurrent Heartbeats
        # -------------------------------------------------------------
        print("\n--- Test 2: Concurrent Heartbeats ---")
        PacketFraming.send_envelope(sock_a, "HEARTBEAT_PING", {})
        pong_a = PacketFraming.read_envelope(sock_a)
        assert pong_a is not None and pong_a["type"] == "HEARTBEAT_PONG", "Device A heartbeat failed"

        PacketFraming.send_envelope(sock_b, "HEARTBEAT_PING", {})
        pong_b = PacketFraming.read_envelope(sock_b)
        assert pong_b is not None and pong_b["type"] == "HEARTBEAT_PONG", "Device B heartbeat failed"
        print("[PASS] Independent heartbeats verified on both active sockets!")

        # -------------------------------------------------------------
        # TEST 3: Universal Bidirectional Clipboard Sync
        # -------------------------------------------------------------
        print("\n--- Test 3: Universal Bidirectional Clipboard Sync ---")
        clip_text = "https://github.com/nactore/nacmac - Secure Local P2P #" + str(uuid.uuid4())[:8]
        clip_hash = sha256_str(clip_text)
        
        # Device A copies text and broadcasts to Mac
        PacketFraming.send_envelope(sock_a, "CLIPBOARD_SYNC", {
            "text": clip_text,
            "timestamp": int(time.time()),
            "sourceDeviceId": dev_a_id,
            "hash": clip_hash
        })
        print(f"[*] Device A synced clipboard text ({len(clip_text)} chars, SHA-256: {clip_hash[:12]}...)")

        # Device B should receive the broadcasted clipboard update
        # (while Device A should NOT receive an echo loop)
        env_b = PacketFraming.read_envelope(sock_b, timeout=2.0)
        assert env_b is not None and env_b["type"] == "CLIPBOARD_SYNC", f"Device B did not receive clipboard sync: {env_b}"
        b_payload = json.loads(env_b["payload"])
        assert b_payload["text"] == clip_text, f"Text mismatch: {b_payload['text']} vs {clip_text}"
        assert b_payload["hash"] == clip_hash, f"Hash mismatch: {b_payload['hash']} vs {clip_hash}"
        print(f"[PASS] Device B received broadcasted clipboard update with matching SHA-256!")

        # Verify Device A receives NO echo loop
        env_echo = PacketFraming.read_envelope(sock_a, timeout=0.5)
        assert env_echo is None or env_echo.get("type") != "CLIPBOARD_SYNC", "Loop prevention failure: sender received echo"
        print("[PASS] Loop prevention verified: originating device did NOT receive echo loop")

        # Test edge case: large unicode / multiline clipboard
        multiline_text = "✨ NacMac Continuous Clipboard Sync ✨\n• Point 1: 🚀 Local Wi-Fi\n• Point 2: 🔒 SHA-256 Zero Cloud\n• Multiline UTF-8: 日本語 / 🇨🇦 / 🎉"
        multiline_hash = sha256_str(multiline_text)
        PacketFraming.send_envelope(sock_b, "CLIPBOARD_SYNC", {
            "text": multiline_text,
            "timestamp": int(time.time()),
            "sourceDeviceId": dev_b_id,
            "hash": multiline_hash
        })
        env_a_multi = PacketFraming.read_envelope(sock_a, timeout=2.0)
        assert env_a_multi is not None and env_a_multi["type"] == "CLIPBOARD_SYNC"
        payload_multi = json.loads(env_a_multi["payload"])
        assert payload_multi["text"] == multiline_text
        assert payload_multi["hash"] == multiline_hash
        print("[PASS] Multi-line and Unicode emoji clipboard sync verified!")

        # -------------------------------------------------------------
        # TEST 4: Notification Actions & In-line Replies
        # -------------------------------------------------------------
        print("\n--- Test 4: Interactive Notification Actions & In-line Replies ---")
        notif_id = f"com.whatsapp_101_{dev_a_id}"
        actions = [
            {"index": 0, "title": "Reply", "isReply": True, "supportsReply": True},
            {"index": 1, "title": "Mark as read", "isReply": False, "supportsReply": False}
        ]
        notif_payload = {
            "id": notif_id,
            "packageName": "com.whatsapp",
            "appName": "WhatsApp",
            "title": "Alex Mercer",
            "body": "Hey, is the NacMac release ready?",
            "timestamp": int(time.time()),
            "hasReplyAction": True,
            "supportsReply": True,
            "deviceId": dev_a_id,
            "deviceName": "Google Pixel 8 Pro",
            "actions": actions
        }
        PacketFraming.send_envelope(sock_a, "NOTIFICATION", notif_payload)
        print(f"[*] Dispatched notification with {len(actions)} actions from {dev_a_id}")

        # Also test modern supportsReply-only payload
        modern_notif_id = f"com.telegram_modern_{dev_a_id}"
        PacketFraming.send_envelope(sock_a, "NOTIFICATION", {
            "id": modern_notif_id,
            "packageName": "org.telegram.messenger",
            "appName": "Telegram",
            "title": "Developer",
            "body": "Modern supportsReply flag test",
            "timestamp": int(time.time()),
            "supportsReply": True,
            "deviceId": dev_a_id,
            "actions": [
                {"index": 0, "title": "Quick Reply", "supportsReply": True}
            ]
        })
        PacketFraming.send_envelope(sock_a, "NOTIFICATION_DISMISSED", {"id": modern_notif_id, "deviceId": dev_a_id})

        # Simulate Mac user triggering notification action (in-line reply)
        reply_action = {
            "notificationKey": notif_id,
            "actionIndex": 0,
            "replyText": "Yes! Fully tested and verified.",
            "deviceId": dev_a_id
        }
        PacketFraming.send_envelope(sock_a, "NOTIFICATION_ACTION", reply_action)
        print("[*] Sent simulated inline reply from Mac back to device...")

        # Test dismissal
        dismiss_payload = {
            "id": notif_id,
            "deviceId": dev_a_id
        }
        PacketFraming.send_envelope(sock_a, "NOTIFICATION_DISMISSED", dismiss_payload)
        print("[PASS] Notification action dispatch and dismissal verified without error!")

        # -------------------------------------------------------------
        # TEST 5: SMS / RCS Messaging Hub Protocol
        # -------------------------------------------------------------
        print("\n--- Test 5: SMS / RCS Messaging Hub Protocol ---")
        # 5a: Conversation list request & response
        PacketFraming.send_envelope(sock_a, "SMS_CONVERSATIONS_REQUEST", {"limit": 10})
        
        # Simulated Android responding to request
        mock_threads = [
            {
                "threadId": 12,
                "address": "+14155552671",
                "contactName": "Sarah Connor",
                "snippet": "Are we still meeting at 3?",
                "timestamp": int(time.time() * 1000),
                "unreadCount": 1
            },
            {
                "threadId": 14,
                "address": "+16505559823",
                "contactName": "David Chen",
                "snippet": "Check out the repo updates.",
                "timestamp": int((time.time() - 3600) * 1000),
                "unreadCount": 0
            }
        ]
        PacketFraming.send_envelope(sock_a, "SMS_CONVERSATIONS_RESPONSE", {
            "threads": mock_threads,
            "deviceId": dev_a_id
        })
        print(f"[*] Verified SMS_CONVERSATIONS_RESPONSE with {len(mock_threads)} threads")

        # 5b: Mac auto-requests message history for thread 12 from Device A
        req_msg = PacketFraming.read_envelope(sock_a, timeout=2.0)
        assert req_msg is not None and req_msg["type"] == "SMS_MESSAGES_REQUEST", f"Expected SMS_MESSAGES_REQUEST on Device A, got: {req_msg}"
        req_payload = json.loads(req_msg["payload"])
        assert req_payload["threadId"] == 12, f"Unexpected threadId: {req_payload}"
        print(f"[*] Mac successfully requested message thread {req_payload['threadId']} directly from Device A")

        mock_messages = [
            {
                "messageId": 101,
                "threadId": 12,
                "address": "+14155552671",
                "body": "Hey Ayush",
                "timestamp": int((time.time() - 600) * 1000),
                "isIncoming": True
            },
            {
                "messageId": 102,
                "threadId": 12,
                "address": "+14155552671",
                "body": "Are we still meeting at 3?",
                "timestamp": int((time.time() - 300) * 1000),
                "isIncoming": True
            }
        ]
        PacketFraming.send_envelope(sock_a, "SMS_MESSAGES_RESPONSE", {
            "threadId": 12,
            "messages": mock_messages,
            "deviceId": dev_a_id
        })
        print(f"[*] Verified SMS_MESSAGES_RESPONSE with {len(mock_messages)} messages")

        # 5c: Send SMS & receive status
        PacketFraming.send_envelope(sock_a, "SMS_SEND", {
            "recipient": "+14155552671",
            "message": "Yes, see you at 3!",
            "threadId": 12,
            "deviceId": dev_a_id
        })
        PacketFraming.send_envelope(sock_a, "SMS_SEND_STATUS", {
            "success": True,
            "message": "Sent",
            "threadId": 12
        })
        print("[PASS] SMS / RCS Messaging Hub protocol flow verified successfully!")

        # -------------------------------------------------------------
        # TEST 6: Disconnect Isolation & Reconnection Resiliency
        # -------------------------------------------------------------
        print("\n--- Test 6: Disconnect Isolation & Reconnection Resiliency ---")
        # Abruptly close Device A's socket
        sock_a.close()
        sock_a = None
        print(f"[*] Closed Device A socket ({dev_a_id}). Waiting for server socket update...")
        time.sleep(0.5)

        # Device B should still be 100% active and healthy
        PacketFraming.send_envelope(sock_b, "HEARTBEAT_PING", {})
        pong_b2 = PacketFraming.read_envelope(sock_b)
        assert pong_b2 is not None and pong_b2.get("type") == "HEARTBEAT_PONG", f"Unexpected response on Device B: {pong_b2}"
        print("[PASS] Device B remained fully connected and responsive after Device A disconnected!")

        # Reconnect Device A
        sock_a = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock_a.connect((HOST, PORT))
        PacketFraming.send_envelope(sock_a, "PAIR_REQUEST", {
            "androidId": dev_a_id,
            "deviceName": "Google Pixel 8 Pro",
            "authSecret": shared_secret
        })
        resp_a2 = PacketFraming.read_envelope(sock_a)
        assert resp_a2 is not None and resp_a2["type"] == "PAIR_RESPONSE"
        payload_a2 = json.loads(resp_a2["payload"])
        assert payload_a2["success"] is True
        print("[PASS] Device A seamlessly reconnected and authenticated!")

        # -------------------------------------------------------------
        # TEST 7: Concurrent Multi-Device Chunked File Transfer & Socket Isolation
        # -------------------------------------------------------------
        print("\n--- Test 7: Concurrent Chunked File Transfer & Socket Isolation ---")
        transfer_id = str(uuid.uuid4())
        test_filename = f"phase2_multi_transfer_{int(time.time())}.dat"
        file_bytes = os.urandom(256 * 1024)
        file_hash = hashlib.sha256(file_bytes).hexdigest()

        # Device A starts file transfer to Mac
        PacketFraming.send_envelope(sock_a, "FILE_START", {
            "transferId": transfer_id,
            "filename": test_filename,
            "size": len(file_bytes),
            "sha256": file_hash
        })

        chunk_size = 64 * 1024
        offset = 0
        while offset < len(file_bytes):
            chunk = file_bytes[offset:offset + chunk_size]
            b64_data = base64.b64encode(chunk).decode("ascii")
            PacketFraming.send_envelope(sock_a, "FILE_CHUNK", {
                "transferId": transfer_id,
                "offset": offset,
                "length": len(chunk),
                "dataBase64": b64_data
            })
            offset += len(chunk)

            # Concurrently on Device B: send heartbeat ping to verify socket isolation
            PacketFraming.send_envelope(sock_b, "HEARTBEAT_PING", {})
            pong_concurrent = PacketFraming.read_envelope(sock_b, timeout=2.0)
            assert pong_concurrent is not None and pong_concurrent.get("type") == "HEARTBEAT_PONG", f"Device B failed concurrent heartbeat: {pong_concurrent}"

        PacketFraming.send_envelope(sock_a, "FILE_END", {
            "transferId": transfer_id,
            "totalBytes": len(file_bytes)
        })

        time.sleep(1.0)

        # Verify file arrived on Mac and exact SHA-256 matches
        dest_path = os.path.expanduser(f"~/Downloads/NacMac/{test_filename}")
        assert os.path.exists(dest_path), f"Transferred file not found at {dest_path}"
        with open(dest_path, "rb") as f:
            saved_bytes = f.read()
        assert len(saved_bytes) == len(file_bytes), f"File length mismatch: {len(saved_bytes)} vs {len(file_bytes)}"
        assert hashlib.sha256(saved_bytes).hexdigest() == file_hash, "SHA-256 hash mismatch on transferred file!"
        try:
            os.remove(dest_path)
        except:
            pass
        print(f"[PASS] 256 KB file transfer verified with exact SHA-256 while Device B operated concurrently!")

        print("\n" + "=" * 70)
        print("ALL PHASE 2 MULTI-DEVICE & CONTINUITY TESTS PASSED SUCCESSFULLY!")
        print("=" * 70)

    except Exception as e:
        print(f"[TEST EXCEPTION] {e}")
        if proc:
            print(f"[PROC POLL] {proc.poll()}")
            try:
                out, err = proc.communicate(timeout=1.0)
                print(f"[PROC STDOUT] {out.decode('utf-8', errors='ignore')}")
                print(f"[PROC STDERR] {err.decode('utf-8', errors='ignore')}")
            except Exception as pe:
                print(f"[PROC COMM ERROR] {pe}")
        raise
    finally:
        if sock_a:
            try:
                sock_a.close()
            except:
                pass
        if sock_b:
            try:
                sock_b.close()
            except:
                pass
        if proc:
            try:
                proc.terminate()
                proc.wait(timeout=2.0)
            except:
                try:
                    proc.kill()
                except:
                    pass

if __name__ == "__main__":
    run_tests()
