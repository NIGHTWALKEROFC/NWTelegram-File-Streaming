from flask import Flask, Response, request
import webbrowser
import threading

app = Flask(__name__)
client = None
message = None

@app.route("/")
def home():
    return """
    <html>
    <body style="background:black;">
    <video width="100%" controls autoplay>
        <source src="/stream" type="video/mp4">
    </video>
    </body>
    </html>
    """

@app.route("/stream")
def stream():
    file_size = message.file.size
    range_header = request.headers.get("Range", None)

    start = 0
    end = file_size - 1

    if range_header:
        start = int(range_header.split("=")[1].split("-")[0])

    chunk_size = 1024 * 1024

    def generate():
        for chunk in client.iter_download(
            message.document,
            offset=start,
            request_size=chunk_size
        ):
            yield chunk

    headers = {
        "Content-Range": f"bytes {start}-{end}/{file_size}",
        "Accept-Ranges": "bytes",
        "Content-Type": "video/mp4",
    }

    return Response(generate(), status=206, headers=headers)

def start_server(cli, msg):
    global client, message
    client = cli
    message = msg

    print("🚀 Server running at http://127.0.0.1:8000")

    # Auto open browser
    threading.Timer(2, lambda: webbrowser.open("http://127.0.0.1:8000")).start()

    app.run(host="127.0.0.1", port=8000)
