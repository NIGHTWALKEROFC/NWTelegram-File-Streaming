import re
import asyncio
from telethon import TelegramClient
from utils import extract_link
from streamer import start_server

api_id = int(input("Enter API ID: "))
api_hash = input("Enter API HASH: ")

client = TelegramClient("session", api_id, api_hash)

async def main():
    await client.start()
    print("✅ Logged in successfully")

    link = input("Paste Telegram link: ")

    chat, msg_id = extract_link(link)

    message = await client.get_messages(chat, ids=msg_id)

    if not message or not message.document:
        print("❌ No file found in this message")
        return

    print(f"📁 File: {message.file.name}")
    print(f"📦 Size: {message.file.size / (1024*1024):.2f} MB")

    await start_server(client, message)

asyncio.run(main())
