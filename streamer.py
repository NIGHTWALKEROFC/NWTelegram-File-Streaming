from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, HTMLResponse
import uvicorn

app = FastAPI()
client = None
message = None

@app.get("/")
def home():
    return HTMLResponse("""
    <html>
    <body style="background:black;">
    <video width="100%" controls autoplay>
        <source src="/stream" type="video/mp4">
    </video>
    </body>
    </html>
    """)

@app.get("/stream")
async def stream(request: Request):
    file_size = message.file.size

    range_header = request.headers.get("range")
    start = 0
    end = file_size - 1

    if range_header:
        start = int(range_header.split("=")[1].split("-")[0])

    chunk_size = 1024 * 1024

    async def file_iterator():
        async for chunk in client.iter_download(
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

    return StreamingResponse(file_iterator(), status_code=206, headers=headers)

async def start_server(cli, msg):
    global client, message
    client = cli
    message = msg

    print("🚀 Starting server at http://127.0.0.1:8000")
    print("🌐 Open in browser...")

    uvicorn.run(app, host="127.0.0.1", port=8000)
