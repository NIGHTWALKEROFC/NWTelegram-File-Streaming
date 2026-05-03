from flask import Flask, Response, request
import threading
import webbrowser
import os

app = Flask(__name__)

file_path = "temp_video.mp4"
client = None
message = None

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
    file_size = os.path.getsize(file_path)
    range_header = request.headers.get("Range", None)

    start = 0
    end = file_size - 1

    if range_header:
        start = int(range_header.split("=")[1].split("-")[0])

    def generate():
        with open(file_path, "rb") as f:
            f.seek(start)
            while True:
                chunk = f.read(1024 * 512)
                if not chunk:
                    break
                yield chunk

    headers = {
        "Content-Range": f"bytes {start}-{end}/{file_size}",
        "Accept-Ranges": "bytes",
        "Content-Type": "video/mp4",
    }

    return Response(generate(), status=206, headers=headers)


def download_file():
    print("⬇️ Downloading file...")
    client.loop.run_until_complete(
        client.download_media(message.document, file_path)
    )
    print("✅ Download complete")


def start_server(cli, msg):
    global client, message
    client = cli
    message = msg

    # Start downloading in background
    threading.Thread(target=download_file).start()

    print("🚀 Server running at http://127.0.0.1:8000")

    threading.Timer(2, lambda: webbrowser.open("http://127.0.0.1:8000")).start()

    app.run(host="127.0.0.1", port=8000)
