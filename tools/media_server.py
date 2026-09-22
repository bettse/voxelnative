#!/opt/homebrew/bin/python3.13
"""
Luanti "remote media" server: serves a game's media files by sha1 over HTTP so
clients fetch them in parallel instead of over the game's UDP connection.

  GET /index.mth      -> u32 'MTHS' signature, u16 version 1, then 20-byte sha1s
  GET /<sha1 hex>     -> the file

Point the game server at it with  remote_media = http://<host>:8099/  and
restart it. Usage: tools/media_server.py [--port 8099] [--root <game dir>]
"""
import argparse, hashlib, http.server, os, struct, sys, threading

EXTS = {".png", ".jpg", ".jpeg", ".tga", ".ogg", ".b3d", ".x", ".obj", ".gltf", ".glb", ".tr", ".po", ".mo", ".ttf", ".otf"}


def index(root):
    files = {}
    for dirpath, _, names in os.walk(root):
        for n in names:
            if os.path.splitext(n)[1].lower() not in EXTS:
                continue
            p = os.path.join(dirpath, n)
            with open(p, "rb") as f:
                files[hashlib.sha1(f.read()).digest()] = p
    return files


class Handler(http.server.BaseHTTPRequestHandler):
    files = {}
    hashset = b""

    def log_message(self, fmt, *args):
        if "index.mth" in self.path or "-v" in sys.argv:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        name = self.path.strip("/")
        if name == "index.mth":
            return self._send(self.hashset, "application/octet-stream")
        try:
            digest = bytes.fromhex(name)
        except ValueError:
            return self.send_error(404)
        p = self.files.get(digest)
        if not p:
            return self.send_error(404)
        with open(p, "rb") as f:
            self._send(f.read(), "application/octet-stream")

    def _send(self, data, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--root", default=os.path.expanduser("~/Library/Application Support/minetest/games/mineclone2"))
    ap.add_argument("-v", action="store_true")
    args = ap.parse_args()
    files = index(args.root)
    Handler.files = files
    Handler.hashset = struct.pack(">IH", 0x4D544853, 1) + b"".join(sorted(files))
    print("serving %d media files from %s on port %d" % (len(files), args.root, args.port), flush=True)
    Server(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
