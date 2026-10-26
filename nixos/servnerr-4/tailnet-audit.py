"""Fetch the tailnet's configuration audit log since the last run and print
each event as one JSON line, for the journal.

The API wants a time window with both ends. The window starts at the newest
event already printed, kept in the state directory, and events at or before
that instant are skipped since the window is inclusive. A first run looks a
week back, which is less than the API keeps.
"""

import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://api.tailscale.com/api/v2"


def parse(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def read(path):
    with open(path) as f:
        return f.read().strip()


def post(url, data):
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def get(url, token):
    headers = {"Authorization": f"Bearer {token}"}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def main():
    creds = os.environ["CREDENTIALS_DIRECTORY"]
    state = os.path.join(os.environ["STATE_DIRECTORY"], "last")
    now = datetime.datetime.now(datetime.timezone.utc)
    try:
        last = parse(read(state))
    except FileNotFoundError:
        last = now - datetime.timedelta(days=7)

    token = post(
        f"{API}/oauth/token",
        {
            "client_id": read(os.path.join(creds, "client_id")),
            "client_secret": read(os.path.join(creds, "client_secret")),
        },
    )["access_token"]

    query = urllib.parse.urlencode(
        {"start": last.isoformat(), "end": now.isoformat()}
    )
    url = f"{API}/tailnet/-/logging/configuration?{query}"
    logs = get(url, token).get("logs") or []

    newest = last
    for event in logs:
        when = parse(event["eventTime"])
        if when <= last:
            continue
        print(json.dumps(event, separators=(",", ":")), flush=True)
        newest = max(newest, when)

    tmp = state + ".tmp"
    with open(tmp, "w") as f:
        f.write(newest.isoformat())
    os.replace(tmp, state)


if __name__ == "__main__":
    sys.exit(main())
