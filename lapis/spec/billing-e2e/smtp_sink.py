# Minimal SMTP sink: accepts every message and writes it to /mail/<n>.eml.
import asyncio, time
async def handle(r, w):
    w.write(b"220 sink ESMTP\r\n"); await w.drain()
    data, buf = False, []
    while True:
        line = await r.readline()
        if not line: break
        if data:
            if line in (b".\r\n", b".\n"):
                data = False
                open(f"/mail/{time.time_ns()}.eml", "wb").write(b"".join(buf)); buf = []
                w.write(b"250 2.0.0 queued\r\n")
            else:
                buf.append(line)
            await w.drain(); continue
        cmd = line[:4].upper()
        if cmd == b"EHLO": w.write(b"250-sink\r\n250 8BITMIME\r\n")
        elif cmd == b"DATA": data = True; w.write(b"354 end with .\r\n")
        elif cmd == b"QUIT": w.write(b"221 bye\r\n"); await w.drain(); break
        else: w.write(b"250 OK\r\n")
        await w.drain()
    w.close()
async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", 2525)
    async with server: await server.serve_forever()
asyncio.run(main())
