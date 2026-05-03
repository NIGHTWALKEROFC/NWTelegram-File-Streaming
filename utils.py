import re

def extract_link(link):
    if "t.me/c/" in link:
        parts = link.split("/")
        chat = int("-100" + parts[-2])
        msg_id = int(parts[-1])
        return chat, msg_id

    elif "t.me/" in link:
        parts = link.split("/")
        chat = parts[-2]
        msg_id = int(parts[-1])
        return chat, msg_id

    else:
        raise Exception("Invalid link format")
