#!/usr/bin/env python3
"""持续传输的长连接：故障前后看它断没断、停了多久、丢了多少。

用法：stream-client.py --target IP:端口 [--src-base IP --count N] [--interval 秒] [--duration 秒]

对端是 labsrv 的 --echo 端口（原样发回）。同时开 N 条连接，第 i 条的源地址是 src-base 加 i。
每条连接每隔 interval 秒发一行“序号 发送时间”，对端发回来之后记下到达时间。结束时对每条连接给出：
  - broken：连接是不是断了（对端关闭、重置、发送失败），以及断在什么时候；
  - sent / echoed：发出和收回的行数。连接没断时两者应当相等，差值就是丢的；
  - max_gap：相邻两行回来的最大间隔，也就是这条连接“卡住”的最长时间，以及它发生的时刻。
标准输出是一行 JSON：每条连接的结果，加上汇总。
"""
import argparse
import asyncio
import ipaddress
import json
import time

ap = argparse.ArgumentParser()
ap.add_argument("--target", required=True)
ap.add_argument("--src-base")
ap.add_argument("--count", type=int, default=1)
ap.add_argument("--interval", type=float, default=0.02)
ap.add_argument("--duration", type=float, default=30)
ARGS = ap.parse_args()
HOST, PORT = ARGS.target.rsplit(":", 1)


async def one(i, deadline):
    src = str(ipaddress.ip_address(ARGS.src_base) + i) if ARGS.src_base else None
    r = {"src": src, "sent": 0, "echoed": 0, "broken": None, "max_gap": 0.0, "gap_at": None, "connected": False}
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(HOST, int(PORT), local_addr=(src, 0) if src else None), 5)
    except (OSError, asyncio.TimeoutError) as e:
        r["broken"] = f"建连失败：{e!r}"
        return r
    r["connected"] = True
    r["sport"] = writer.get_extra_info("sockname")[1]
    last = time.time()

    async def recv():
        nonlocal last
        while True:
            line = await reader.readline()
            if not line:
                raise ConnectionError("对端关闭")
            now = time.time()
            if now - last > r["max_gap"]:
                r["max_gap"], r["gap_at"] = round(now - last, 3), round(last, 3)
            last = now
            r["echoed"] += 1

    task = asyncio.ensure_future(recv())
    try:
        while time.time() < deadline:
            writer.write(f"{r['sent']} {time.time():.3f}\n".encode())
            r["sent"] += 1
            await writer.drain()
            await asyncio.sleep(ARGS.interval)
            if task.done():
                task.result()
        # 收尾：最多再等 5 秒，让在途的行回来
        for _ in range(50):
            if r["echoed"] >= r["sent"] or task.done():
                break
            await asyncio.sleep(0.1)
        if task.done():
            task.result()
    except (OSError, ConnectionError) as e:
        r["broken"] = f"{e!r}"
        r["broken_at"] = round(time.time(), 3)
    finally:
        task.cancel()
        writer.close()
    return r


async def main():
    deadline = time.time() + ARGS.duration
    res = await asyncio.gather(*(one(i, deadline) for i in range(ARGS.count)))
    alive = [r for r in res if r["connected"] and not r["broken"]]
    out = {
        "conns": len(res),
        "connected": sum(r["connected"] for r in res),
        "survived": len(alive),
        "broken": len(res) - len(alive),
        "lost_lines_on_survivors": sum(r["sent"] - r["echoed"] for r in alive),
        "stalled_over_300ms": sum(r["max_gap"] > 0.3 for r in alive),
        "max_gap": max((r["max_gap"] for r in res), default=0),
        "detail": res,
    }
    print(json.dumps(out, ensure_ascii=False))


asyncio.run(main())
