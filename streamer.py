from flask import Flask, Response, request
import asyncio
import os

app = Flask(__name__)

client = None
message = None
file_path = "temp_video.mp4"


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
    def generate():
        with open(file_path, "rb") as f:
            while True:
                chunk = f.read(1024 * 512)
                if not chunk:
                    break
                yield chunk

    file_size = os.path.getsize(file_path)

    headers = {
        "Content-Type": "video/mp4",
        "Accept-Ranges": "bytes",
    }

    return Response(generate(), headers=headers)


async def download_progressively():
    with open(file_path, "wb") as f:
        async for chunk in client.iter_download(message.document):
            f.write(chunk)


async def start_server(cli, msg):
    global client, message
    client = cli
    message = msg

    print("⬇️ Starting progressive download...")

    # Start download in same loop (safe)
    asyncio.create_task(download_progressively())

    print("🚀 Server running at http://127.0.0.1:8000")

    import webbrowser
    webbrowser.open("http://127.0.0.1:8000")

    app.run(host="127.0.0.1", port=8000)
