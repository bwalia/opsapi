"""A minimal SMTP server for the forms e2e: accepts every message (no TLS, no
auth) and writes it to /w/mail/<n>.eml so the checks can read what was sent."""
import asyncio, itertools, os

OUT = "/w/mail"
counter = itertools.count(1)


async def handle(reader, writer):
    def say(line):
        writer.write((line + "\r\n").encode())

    say("220 sink ESMTP")
    await writer.drain()
    rcpt, data_mode, lines = [], False, []
    while True:
        raw = await reader.readline()
        if not raw:
            break
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if data_mode:
            if line == ".":
                data_mode = False
                path = os.path.join(OUT, "%04d.eml" % next(counter))
                with open(path + ".tmp", "w") as f:
                    f.write("X-Rcpt: " + ",".join(rcpt) + "\n" + "\n".join(lines))
                os.rename(path + ".tmp", path)
                rcpt, lines = [], []
                say("250 OK")
            else:
                lines.append(line[1:] if line.startswith("..") else line)
            await writer.drain()
            continue
        cmd = line.split(" ", 1)[0].upper()
        if cmd in ("EHLO", "HELO"):
            say("250 sink")
        elif cmd == "MAIL":
            say("250 OK")
        elif cmd == "RCPT":
            rcpt.append(line.split(":", 1)[1].strip().strip("<>"))
            say("250 OK")
        elif cmd == "DATA":
            data_mode = True
            say("354 End data with <CR><LF>.<CR><LF>")
        elif cmd == "QUIT":
            say("221 Bye")
            await writer.drain()
            break
        else:
            say("250 OK")
        await writer.drain()
    writer.close()


async def main():
    os.makedirs(OUT, exist_ok=True)
    server = await asyncio.start_server(handle, "0.0.0.0", 2525)
    async with server:
        await server.serve_forever()


asyncio.run(main())
