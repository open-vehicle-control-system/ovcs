"""Exercise the relay against real WebSocket peers without requiring ROS."""

import asyncio
import importlib.util
import unittest
from pathlib import Path

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

spec = importlib.util.spec_from_file_location(
    "foxglove_compression", Path(__file__).resolve().parents[1] / "foxglove_compression.py"
)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class CompressionRelayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.upstream_connections = 0

        async def echo(peer):
            self.upstream_connections += 1
            async for message in peer:
                if message == "close-upstream":
                    await peer.close()
                    return
                await peer.send(message)

        self.upstream = await serve(
            echo, "127.0.0.1", 0, subprotocols=[relay.PROTOCOL],
            compression=None, max_size=None,
        )
        upstream_port = self.upstream.sockets[0].getsockname()[1]

        async def handler(peer):
            await relay.relay(peer, f"ws://127.0.0.1:{upstream_port}")

        self.proxy = await serve(
            handler, "127.0.0.1", 0, subprotocols=[relay.PROTOCOL],
            compression=None, extensions=relay.compression_extensions(), max_size=None,
        )
        self.uri = f"ws://127.0.0.1:{self.proxy.sockets[0].getsockname()[1]}"

    async def asyncTearDown(self):
        self.proxy.close()
        await self.proxy.wait_closed()
        self.upstream.close()
        await self.upstream.wait_closed()

    async def test_compressed_text_and_large_binary_are_lossless(self):
        async with connect(self.uri, subprotocols=[relay.PROTOCOL], max_size=None) as peer:
            self.assertIn("permessage-deflate", peer.response.headers["Sec-WebSocket-Extensions"])
            self.assertEqual(peer.subprotocol, relay.PROTOCOL)
            for message in ['{"op":"subscribe","subscriptions":[]}', bytes(range(256)) * 8192]:
                await peer.send(message)
                self.assertEqual(await asyncio.wait_for(peer.recv(), 3), message)

    async def test_clients_have_separate_sessions_and_compression_is_optional(self):
        async with (
            connect(self.uri, subprotocols=[relay.PROTOCOL]) as first,
            connect(self.uri, subprotocols=[relay.PROTOCOL], compression=None) as second,
        ):
            self.assertNotIn("Sec-WebSocket-Extensions", second.response.headers)
            await first.send("first")
            await second.send("second")
            self.assertEqual(await asyncio.wait_for(first.recv(), 3), "first")
            self.assertEqual(await asyncio.wait_for(second.recv(), 3), "second")
            self.assertEqual(self.upstream_connections, 2)

    async def test_upstream_close_terminates_client_session(self):
        async with connect(self.uri, subprotocols=[relay.PROTOCOL]) as peer:
            await peer.send("close-upstream")
            with self.assertRaises(ConnectionClosed):
                await asyncio.wait_for(peer.recv(), 3)


if __name__ == "__main__":
    unittest.main()
