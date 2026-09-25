#!/usr/bin/env python3
"""Tiny App Store Connect API client (no dependencies beyond openssl).

Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH from native/.env (the same
settings testflight.sh uses). Usage:

  tools/asc.py status                  # TestFlight builds + beta review state
  tools/asc.py get /v1/apps            # raw GET, prints JSON
  tools/asc.py screenshots a.png b.png # replace version 1.0's Vision Pro screenshots, in order
"""
import base64, hashlib, json, os, subprocess, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE_ID = "dev.ericbetts.voxelnative"
API = "https://api.appstoreconnect.apple.com"


def env():
    vals = dict(os.environ)
    path = os.path.join(HERE, "..", "native", ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                vals.setdefault(k.strip(), v.strip())
    missing = [k for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not vals.get(k)]
    if missing:
        sys.exit(f"missing {', '.join(missing)} (set them in native/.env)")
    return vals


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der):
    """ECDSA DER signature -> the 64-byte r||s form JWT's ES256 wants."""
    assert der[0] == 0x30
    i = 2
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n = der[i + 1]
        v = der[i + 2:i + 2 + n].lstrip(b"\x00")
        out += v.rjust(32, b"\x00")
        i += 2 + n
    return out


def token(e):
    header = {"alg": "ES256", "kid": e["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    claims = {"iss": e["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(claims).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.path.expanduser(e["ASC_KEY_PATH"])],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64(der_to_raw(der))}"


def request(method, path, body=None):
    e = env()
    req = urllib.request.Request(API + path if path.startswith("/") else path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token(e)}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as err:
        sys.exit(f"{method} {path} -> HTTP {err.code}: {err.read().decode()[:2000]}")


def app_id():
    apps = request("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"no app record for {BUNDLE_ID}")
    return apps[0]["id"]


def status():
    aid = app_id()
    builds = request("GET", f"/v1/builds?filter[app]={aid}&sort=-uploadedDate&limit=5"
                            "&include=buildBetaDetail,betaAppReviewSubmission")
    inc = {(i["type"], i["id"]): i["attributes"] for i in builds.get("included", [])}
    for b in builds["data"]:
        a, rel = b["attributes"], b["relationships"]
        detail = rel.get("buildBetaDetail", {}).get("data")
        review = rel.get("betaAppReviewSubmission", {}).get("data")
        d = inc.get((detail["type"], detail["id"]), {}) if detail else {}
        r = inc.get((review["type"], review["id"]), {}) if review else {}
        print(f"build {a['version']}  uploaded {a['uploadedDate'][:16]}  processing={a['processingState']}"
              f"  internal={d.get('internalBuildState')}  external={d.get('externalBuildState')}"
              f"  betaReview={r.get('betaReviewState', 'not submitted')}")


def upload_screenshots(paths, display_type="APP_APPLE_VISION_PRO"):
    """Replace the editable version's screenshots for one display type with
    `paths`, in order: reserve each file, PUT its bytes to the URLs Apple hands
    back, commit it with an MD5, then set the set's order."""
    aid = app_id()
    versions = request("GET", f"/v1/apps/{aid}/appStoreVersions")["data"]
    ver = next(v for v in versions if v["attributes"]["appStoreState"] in
               ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"))
    loc = request("GET", f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")["data"][0]
    sets = request("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
    sset = next((x for x in sets if x["attributes"]["screenshotDisplayType"] == display_type), None)
    if sset is None:
        sset = request("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
    for old in request("GET", f"/v1/appScreenshotSets/{sset['id']}/appScreenshots")["data"]:
        request("DELETE", f"/v1/appScreenshots/{old['id']}")
    ids = []
    for path in paths:
        data = open(path, "rb").read()
        shot = request("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sset["id"]}}}}})["data"]
        for op in shot["attributes"]["uploadOperations"]:
            chunk = data[op["offset"]:op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], data=chunk, method=op["method"],
                                         headers={h["name"]: h["value"] for h in op.get("requestHeaders", [])})
            urllib.request.urlopen(req).read()
        request("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        ids.append(shot["id"])
        print(f"uploaded {os.path.basename(path)}")
    request("PATCH", f"/v1/appScreenshotSets/{sset['id']}/relationships/appScreenshots",
            {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
    for _ in range(30):   # Apple processes the images asynchronously
        states = [x["attributes"]["assetDeliveryState"]["state"] for x in
                  request("GET", f"/v1/appScreenshotSets/{sset['id']}/appScreenshots")["data"]]
        if all(st in ("COMPLETE", "FAILED") for st in states):
            break
        time.sleep(5)
    print("states:", states)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        status()
    elif cmd == "screenshots":
        upload_screenshots(sys.argv[2:])
    elif cmd == "get":
        print(json.dumps(request("GET", sys.argv[2]), indent=2))
    else:
        sys.exit(__doc__)
