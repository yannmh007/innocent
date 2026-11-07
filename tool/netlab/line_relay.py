#!/usr/bin/env python3
"""The device lab's shaped line: a transparent TCP relay on the runner.

WHY (7 Nov 2026). The lab shaped the emulator's line by redirecting packets
arriving on the runner's eth0 into ifb0 and putting netem there. On GitHub's
runners eth0 already carries a clsact qdisc whose own filters take every
packet first: our filter was accepted and never saw one (a 600 KB probe
under a "900 kbit" cap came in at 32 Mbit/s, run 42363479008). The weakline
A/B runs before it had been on an unshaped line.

So the bytes are moved onto loopback, where shaping is proven (the
streamlong flows, stream-bench): iptables sends the emulator's outgoing
HTTPS connections (uid of the runner, port 443) here; this relay, running
as root so its own connections are not redirected, opens the connection
the emulator asked for (SO_ORIGINAL_DST) and copies bytes both ways. TLS is
never opened: the app talks to the real servers, certificates and all. What
it sends back to the emulator crosses lo, and netem on lo is the line.

Usage: line_relay.py PORT [STATS_FILE]
  Listens on 127.0.0.1:PORT. On SIGTERM writes one line of counts (no
  addresses) to STATS_FILE, or stderr.
"""
import asyncio
import os
import signal
import socket
import struct
import sys

SO_ORIGINAL_DST = 80  # linux/netfilter_ipv4.h

stats = {'connections': 0, 'refused': 0, 'down_bytes': 0, 'up_bytes': 0}


def original_dst(sock):
    raw = sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
    port = struct.unpack_from('!H', raw, 2)[0]
    return socket.inet_ntoa(raw[4:8]), port


async def pipe(reader, writer, key):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            stats[key] += len(data)
            writer.write(data)
            await writer.drain()
        # The other side may still be answering: pass on the half-close.
        if writer.can_write_eof():
            writer.write_eof()
    except (ConnectionError, OSError):
        writer.transport.abort()


async def handle(client_r, client_w, own_port):
    sock = client_w.get_extra_info('socket')
    try:
        host, port = original_dst(sock)
        if host.startswith('127.') and port == own_port:
            raise OSError('a connection to the relay itself')
        up_r, up_w = await asyncio.wait_for(asyncio.open_connection(host, port), 20)
    except (OSError, asyncio.TimeoutError):
        stats['refused'] += 1
        client_w.transport.abort()
        return
    stats['connections'] += 1
    await asyncio.gather(pipe(client_r, up_w, 'up_bytes'),
                         pipe(up_r, client_w, 'down_bytes'))
    for w in (up_w, client_w):
        w.close()


def write_stats(path):
    line = ('relay: {connections} connections ({refused} refused), '
            '{down_mb:.1f} MB to the emulator, {up_kb:.1f} KB from it\n').format(
                down_mb=stats['down_bytes'] / 1e6, up_kb=stats['up_bytes'] / 1e3, **stats)
    if path:
        with open(path, 'a') as f:
            f.write(line)
    else:
        sys.stderr.write(line)


async def main():
    port = int(sys.argv[1])
    path = sys.argv[2] if len(sys.argv) > 2 else None
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, port), '127.0.0.1', port, reuse_address=True)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for s in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(s, stop.set)
    await stop.wait()
    # Counts first, then out at once: closing the server politely waits for
    # every connection the emulator still holds open (Python 3.12), and the
    # counts never came (run 42365863693).
    write_stats(path)
    sys.stderr.flush()
    os._exit(0)


if __name__ == '__main__':
    asyncio.run(main())
