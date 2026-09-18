"""Relay Foxglove messages with lossless WebSocket compression."""

import argparse
import asyncio
import logging
import signal

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed, InvalidHandshake
from websockets.extensions.permessage_deflate import ServerPerMessageDeflateFactory

PROTOCOL = "foxglove.sdk.v1"
LOG = logging.getLogger("foxglove_compression")


async def forward(source, destination):
    async for message in source:
        await destination.send(message)


async def relay(client, upstream_uri):
    """Give each client its own upstream session and preserve message ordering."""
    try:
        async with connect(
            upstream_uri,
            subprotocols=[PROTOCOL],
            compression=None,
            proxy=None,
            max_size=None,
            max_queue=1,
            write_limit=32768,
            close_timeout=2,
        ) as upstream:
            LOG.info(
                "Client connected; compression=%s",
                client.response.headers.get("Sec-WebSocket-Extensions", "none"),
            )
            tasks = [
                asyncio.create_task(forward(upstream, client)),
                asyncio.create_task(forward(client, upstream)),
            ]
            try:
                done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
    except ConnectionClosed:
        pass
    except (OSError, TimeoutError, InvalidHandshake) as error:
        LOG.warning("Bridge connection failed: %s", error)
        await client.close(code=1013, reason="Bridge unavailable; reconnect")


def compression_extensions():
    # Level 1 keeps compression work small on the vehicle CPU. Independent
    # messages bound compression state and match the measured per-frame cost.
    return [
        ServerPerMessageDeflateFactory(
            server_no_context_takeover=True,
            compress_settings={"level": 1},
        )
    ]


async def run(args):
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    async def handler(client):
        await relay(client, f"ws://127.0.0.1:{args.upstream_port}")

    async with serve(
        handler,
        "0.0.0.0",
        args.port,
        subprotocols=[PROTOCOL],
        extensions=compression_extensions(),
        compression=None,
        max_size=None,
        max_queue=1,
        write_limit=32768,
        close_timeout=2,
    ):
        LOG.info("Listening on port %d; upstream on loopback:%d", args.port, args.upstream_port)
        await stop.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    args = parser.parse_args()
    if not (1 <= args.port <= 65535 and 1 <= args.upstream_port <= 65535):
        parser.error("ports must be between 1 and 65535")
    if args.port == args.upstream_port:
        parser.error("public and upstream ports must differ")
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    asyncio.run(run(args))
