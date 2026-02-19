#!/usr/bin/env python3
"""
Run this once to authorize the app and save tokens to /app/data/token.json.
Uses device code flow — no browser on the Pi needed.
"""
import requests
import json
import os
import time

CONFIG_PATH = "/app/data/config.json"
TOKEN_PATH  = "/app/data/token.json"

with open(CONFIG_PATH) as f:
    config = json.load(f)

CLIENT_ID = config["client_id"]
TENANT_ID = config["tenant_id"]
SCOPE     = "https://graph.microsoft.com/Mail.Read offline_access"

# ── Step 1: Request device code ───────────────────────────────────────────────
resp = requests.post(
    f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/devicecode",
    data={"client_id": CLIENT_ID, "scope": SCOPE}
)
resp.raise_for_status()
data = resp.json()

print("\n" + "="*60)
print("Open this URL in your browser:")
print(f"  {data['verification_uri']}")
print(f"\nEnter this code: {data['user_code']}")
print("="*60 + "\n")

# ── Step 2: Poll for token ────────────────────────────────────────────────────
interval = data.get("interval", 5)
expires  = time.time() + data.get("expires_in", 900)

while time.time() < expires:
    time.sleep(interval)
    token_resp = requests.post(
        f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token",
        data={
            "grant_type":  "urn:ietf:params:oauth:grant-type:device_code",
            "client_id":   CLIENT_ID,
            "device_code": data["device_code"],
        }
    )
    token_data = token_resp.json()

    if "access_token" in token_data:
        with open(TOKEN_PATH, "w") as f:
            json.dump(token_data, f, indent=2)
        print(f"✓ Tokens saved to {TOKEN_PATH}")
        print("You can now run fetch.py normally.")
        break
    elif token_data.get("error") == "authorization_pending":
        print("Waiting for authorization...")
    else:
        print(f"Error: {token_data}")
        break
