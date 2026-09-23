#!/opt/homebrew/bin/python3.13
"""
Log into the developer's local VoxeLibre dev server (tools/server.sh) with a
test account, using miney's protocol layer, and save the join-time server
messages as parser fixtures (tools/join-fixtures/).

The binary capture holds each server-to-client message as  u16 opcode,
u32 length, payload  so LuantiKit's decoders can be unit-tested offline
against real VoxeLibre data. The text log lists both directions with opcode
names and sizes.

Usage:
  tools/capture_join_fixtures.py [--host 127.0.0.1] [--port 30000] [--name vrdev]
                     [--password vrdev] [--register] [--seconds 20]
"""
import argparse, os, struct, sys, time, logging

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "repos", "miney"))
from miney.luanticlient import LuantiClient          # noqa: E402
from miney.luanticlient.protocol import Protocol     # noqa: E402

TOCLIENT = {
    0x02: "HELLO", 0x03: "AUTH_ACCEPT", 0x04: "ACCEPT_SUDO_MODE", 0x05: "DENY_SUDO_MODE",
    0x0A: "ACCESS_DENIED", 0x20: "BLOCKDATA", 0x21: "ADDNODE", 0x22: "REMOVENODE",
    0x27: "INVENTORY", 0x29: "TIME_OF_DAY", 0x2A: "CSM_RESTRICTION_FLAGS", 0x2B: "PLAYER_SPEED",
    0x2C: "MEDIA_PUSH", 0x2F: "CHAT_MESSAGE", 0x31: "ACTIVE_OBJECT_REMOVE_ADD",
    0x32: "ACTIVE_OBJECT_MESSAGES", 0x33: "HP", 0x34: "MOVE_PLAYER", 0x35: "ACCESS_DENIED_LEGACY",
    0x36: "FOV", 0x37: "DEATHSCREEN_LEGACY", 0x38: "MEDIA", 0x3A: "NODEDEF", 0x3C: "ANNOUNCE_MEDIA",
    0x3D: "ITEMDEF", 0x3F: "PLAY_SOUND", 0x40: "STOP_SOUND", 0x41: "PRIVILEGES",
    0x42: "INVENTORY_FORMSPEC", 0x43: "DETACHED_INVENTORY", 0x44: "SHOW_FORMSPEC", 0x45: "MOVEMENT",
    0x46: "SPAWN_PARTICLE", 0x47: "ADD_PARTICLESPAWNER", 0x48: "CAMERA", 0x49: "HUDADD", 0x4A: "HUDRM",
    0x4B: "HUDCHANGE", 0x4C: "HUD_SET_FLAGS", 0x4D: "HUD_SET_PARAM", 0x4E: "BREATH", 0x4F: "SET_SKY",
    0x50: "OVERRIDE_DAY_NIGHT_RATIO", 0x51: "LOCAL_PLAYER_ANIMATIONS", 0x52: "EYE_OFFSET",
    0x53: "DELETE_PARTICLESPAWNER", 0x54: "CLOUD_PARAMS", 0x55: "FADE_SOUND", 0x56: "UPDATE_PLAYER_LIST",
    0x57: "MODCHANNEL_MSG", 0x58: "MODCHANNEL_SIGNAL", 0x59: "NODEMETA_CHANGED", 0x5A: "SET_SUN",
    0x5B: "SET_MOON", 0x5C: "SET_STARS", 0x5D: "MOVE_PLAYER_REL", 0x60: "SRP_BYTES_S_B",
    0x61: "FORMSPEC_PREPEND", 0x62: "MINIMAP_MODES", 0x63: "SET_LIGHTING", 0x64: "SPAWN_PARTICLE_BATCH",
}
TOSERVER = {
    0x02: "INIT", 0x11: "INIT2", 0x17: "MODCHANNEL_JOIN", 0x18: "MODCHANNEL_LEAVE", 0x19: "MODCHANNEL_MSG",
    0x23: "PLAYERPOS", 0x24: "GOTBLOCKS", 0x25: "DELETEDBLOCKS", 0x31: "INVENTORY_ACTION",
    0x32: "CHAT_MESSAGE", 0x35: "DAMAGE", 0x37: "PLAYERITEM", 0x38: "RESPAWN_LEGACY", 0x39: "INTERACT",
    0x3A: "REMOVED_SOUNDS", 0x3B: "NODEMETA_FIELDS", 0x3C: "INVENTORY_FIELDS", 0x40: "REQUEST_MEDIA",
    0x41: "HAVE_MEDIA", 0x43: "CLIENT_READY", 0x50: "FIRST_SRP", 0x51: "SRP_BYTES_A", 0x52: "SRP_BYTES_M",
    0x53: "UPDATE_CLIENT_INFO",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=30000)
    ap.add_argument("--name", default="vrdev")
    ap.add_argument("--password", default="vrdev")
    ap.add_argument("--register", action="store_true", help="create the account (FIRST_SRP)")
    ap.add_argument("--seconds", type=float, default=20, help="how long to stay connected after joining")
    ap.add_argument("--protocol", type=int, default=53)
    ap.add_argument("--out", default=os.path.join(HERE, "join-fixtures"))
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    bin_path = os.path.join(args.out, f"{stamp}-toclient.bin")
    txt_path = os.path.join(args.out, f"{stamp}-log.txt")
    binf = open(bin_path, "wb")
    txtf = open(txt_path, "w")
    t0 = time.time()
    counts = {}

    def note(line):
        txtf.write(f"{time.time() - t0:8.3f} {line}\n")
        txtf.flush()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    client = LuantiClient(host=args.host, port=args.port, playername=args.name, password=args.password)
    # Speak the current protocol so the capture matches what the Godot client will see.
    client.protocol = Protocol(protocol_id=0x4F457403, serialization_version=29,
                               protocol_version=args.protocol, version_string="capture_join_fixtures")
    client.connection.protocol = client.protocol

    real_process = client.command_handler.process_command

    def logged_process(opcode, data):
        name = TOCLIENT.get(opcode, f"0x{opcode:02x}")
        counts[name] = counts.get(name, 0) + 1
        note(f"<- {name:28s} {len(data):8d} bytes")
        binf.write(struct.pack(">HI", opcode, len(data)))
        binf.write(data)
        binf.flush()
        try:
            real_process(opcode, data)
        except Exception as e:  # miney's parsers are protocol-39 flavoured; keep capturing
            note(f"   (miney handler error for {name}: {e})")

    client.connection.command_processor = logged_process
    client.command_handler.process_command = logged_process

    real_send = client.connection.send_packet

    def logged_send(data):
        opcode = struct.unpack(">H", data[:2])[0]
        note(f"-> {TOSERVER.get(opcode, f'0x{opcode:02x}'):28s} {len(data) - 2:8d} bytes")
        return real_send(data)

    client.connection.send_packet = logged_send
    client.send_packet = logged_send

    note(f"connecting to {args.host}:{args.port} as {args.name} register={args.register} protocol={args.protocol}")
    ok = client.connect(register=args.register)
    note(f"connect returned {ok}, state={client.state.state}, denied={client.state.access_denied_reason}")
    if ok:
        client.send_chat_message("hello from capture_join_fixtures")
        end = time.time() + args.seconds
        while time.time() < end:
            time.sleep(0.5)
    client.disconnect()
    note("disconnected")
    binf.close()
    txtf.close()
    print(f"capture: {bin_path}\nlog:     {txt_path}")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"{v:6d}  {k}")


if __name__ == "__main__":
    main()
