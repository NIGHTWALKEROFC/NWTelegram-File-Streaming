from flask import Flask, Response, request
import asyncio
import os
import time
import webbrowser

app = Flask(__name__)

client = None
message = None
file_path = "temp_video.mp4"

MIN_BUFFER = 3 * 1024 * 1024  # 3MB buffer


@app.route("/")
def home():
    return """
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="margin:0;background:black;">
    <video style="width:100%;height:100%;" controls autoplay>
        <source src="/stream">
    </video>
    </body>
    </html>
    """


@app.route("/stream")
def stream():
    # wait until minimum buffer is ready
    while True:
        if os.path.exists(file_path) and os.path.getsize(file_path) > MIN_BUFFER:
            break
        time.sleep(0.5)

    def generate():
        with open(file_path, "rb") as f:
            while True:
                chunk = f.read(1024 * 512)
                if chunk:
                    yield chunk
                else:
                    time.sleep(0.3)

    headers = {
        "Content-Type": "video/mp4",
        "Accept-Ranges": "bytes",
    }

    return Response(generate(), headers=headers)


async def download_fast():
    print("⬇️ Downloading...")

    with open(file_path, "wb") as f:
        async for chunk in client.iter_download(
            message.document,
            request_size=1024 * 1024 * 2  # 🔥 2MB chunks = faster
        ):
            f.write(chunk)

    print("✅ Download complete")


async def start_server(cli, msg):
    global client, message
    client = cli
    message = msg

    # Start downloading in background (same loop)
    asyncio.create_task(download_fast())

    print("🚀 Server running at http://127.0.0.1:8000")

    webbrowser.open("http://127.0.0.1:8000")

    app.run(host="127.0.0.1", port=8000)
