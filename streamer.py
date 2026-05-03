from flask import Flask, Response, request
import threading
import webbrowser
import os
import time

app = Flask(__name__)

file_path = "temp_video.mp4"
downloading = True


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
    range_header = request.headers.get("Range", None)

    def generate(start):
        with open(file_path, "rb") as f:
            f.seek(start)

            while True:
                chunk = f.read(1024 * 512)

                if chunk:
                    yield chunk
                else:
                    if downloading:
                        time.sleep(0.5)  # wait for more data
                        continue
                    else:
                        break

    start = 0
    if range_header:
        start = int(range_header.split("=")[1].split("-")[0])

    file_size = os.path.getsize(file_path)

    headers = {
        "Content-Range": f"bytes {start}-{file_size-1}/*",
        "Accept-Ranges": "bytes",
        "Content-Type": "video/mp4",
    }

    return Response(generate(start), status=206, headers=headers)


def start_download(client, message):
    global downloading

    print("⬇️ Downloading in background...")

    with open(file_path, "wb") as f:
        for chunk in client.iter_download(message.document):
            f.write(chunk)

    downloading = False
    print("✅ Download complete")


def start_server(client, message):
    # Start download thread
    threading.Thread(target=start_download, args=(client, message)).start()

    print("🚀 Server running at http://127.0.0.1:8000")

    webbrowser.open("http://127.0.0.1:8000")

    app.run(host="127.0.0.1", port=8000)
