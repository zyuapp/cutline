#!/usr/bin/env python3
"""Drives cutline-mcp over stdio for manual testing.

usage: mcp-session.py <server-binary> <calls.json> [image-dir]
calls.json is a list of {"tool": name, "args": {...}}. Images in results are saved to image-dir.
"""
import base64, json, os, subprocess, sys

server, calls_path = sys.argv[1], sys.argv[2]
image_dir = sys.argv[3] if len(sys.argv) > 3 else "/tmp/cutline-mcp-images"
os.makedirs(image_dir, exist_ok=True)
proc = subprocess.Popen([server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
next_id = 0

def rpc(method, params=None):
    global next_id
    next_id += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}})
print("server:", init["result"]["serverInfo"])
tools = rpc("tools/list")["result"]["tools"]
print(f"{len(tools)} tools")
calls = json.load(open(calls_path))
for i, call in enumerate(calls):
    res = rpc("tools/call", {"name": call["tool"], "arguments": call.get("args", {})})
    result = res.get("result", {})
    flag = "ERROR " if result.get("isError") else ""
    print(f"\n=== {i+1}. {flag}{call['tool']} {json.dumps(call.get('args', {}))[:160]}")
    for c in result.get("content", []):
        if c["type"] == "text":
            print(c["text"])
        elif c["type"] == "image":
            path = os.path.join(image_dir, f"{i+1:02d}-{call['tool']}.jpg")
            open(path, "wb").write(base64.b64decode(c["data"]))
            print(f"[image saved {path}]")
    if "error" in res:
        print("RPC ERROR", res["error"])
proc.stdin.close()
proc.wait()
