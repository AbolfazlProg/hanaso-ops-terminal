#!/usr/bin/env python3
"""CP13 test-only TCP<->Unix-socket forwarder.

Lets a browser OUTSIDE the VM's network namespace reach the REAL :443 TLS
listener INSIDE the VM (outer-side socat replacement — no socat in sandbox):

  outer mode:  cp13-fwd.py outer <listen-port> <unix-path>
               127.0.0.1:<listen-port> -> <unix-path>   (unix socket lives on
               the shared dir, visible to both namespaces)
  inner mode:  cp13-fwd.py inner <unix-path> <target-host> <target-port>
               <unix-path> -> <target-host>:<target-port>   (runs INSIDE the
               VM; target is the panel's real 127.0.0.1:443)

Transport-only relay: TLS and HTTP remain end-to-end between the browser and
the VM's nginx (the relay just moves bytes; it never terminates TLS).
"""
import os
import socket
import sys
import threading


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client, connect_fn):
    try:
        server = connect_fn()
    except OSError as e:
        print("[fwd] upstream connect failed: %s" % e, file=sys.stderr)
        client.close()
        return
    t1 = threading.Thread(target=pump, args=(client, server), daemon=True)
    t2 = threading.Thread(target=pump, args=(server, client), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client.close()
    server.close()


def serve(listener, connect_fn):
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            break
        threading.Thread(target=handle, args=(client, connect_fn), daemon=True).start()


def main():
    mode = sys.argv[1]
    if mode == "outer":
        port = int(sys.argv[2])
        unix_path = sys.argv[3]
        try:
            os.unlink(unix_path)
        except OSError:
            pass

        def connect():
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(unix_path)
            return s

        lst = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        lst.bind(("127.0.0.1", port))
        lst.listen(64)
        print("[fwd] outer: 127.0.0.1:%d -> %s" % (port, unix_path), flush=True)
        serve(lst, connect)
    elif mode == "inner":
        unix_path = sys.argv[2]
        host = sys.argv[3]
        port = int(sys.argv[4])
        try:
            os.unlink(unix_path)
        except OSError:
            pass

        def connect():
            s = socket.create_connection((host, port), timeout=10)
            return s

        lst = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        lst.bind(unix_path)
        os.chmod(unix_path, 0o777)
        lst.listen(64)
        print("[fwd] inner: %s -> %s:%d" % (unix_path, host, port), flush=True)
        serve(lst, connect)
    else:
        sys.exit("usage: cp13-fwd.py outer <port> <unix> | inner <unix> <host> <port>")


if __name__ == "__main__":
    main()
