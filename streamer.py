from flask import Flask, Response, request
import asyncio
import threading
import webbrowser

app = Flask(__name__)
client = None
message = None
loop = None

@app.route("/")
def home():
    return """
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="margin:0;background:black;">
    <video style="width:100%;height:100%;" controls autoplay>
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

    async def async_gen():
        async for chunk in client.iter_download(
            message.document,
            offset=start,
            request_size=chunk_size
        ):
            yield chunk

    def generate():
        agen = async_gen()
        while True:
            try:
                chunk = asyncio.run_coroutine_threadsafe(
                    agen.__anext__(), loop
                ).result()
                yield chunk
            except StopAsyncIteration:
                break

    headers = {
        "Content-Range": f"bytes {start}-{end}/{file_size}",
        "Accept-Ranges": "bytes",
        "Content-Type": "video/mp4",
    }

    return Response(generate(), status=206, headers=headers)

def start_server(cli, msg):
    global client, message, loop
    client = cli
    message = msg
    loop = asyncio.get_event_loop()

    print("🚀 Server running at http://127.0.0.1:8000")

    threading.Timer(2, lambda: webbrowser.open("http://127.0.0.1:8000")).start()

    app.run(host="127.0.0.1", port=8000)
