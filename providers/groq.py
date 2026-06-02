import os
from urllib import request, error
import json
from .base import BaseProvider

class GroqProvider(BaseProvider):
    def __init__(self, api_key: str):
        self.api_key = api_key

    def _call_api(self, audio_path: str, model: str, language: str) -> str:
        if not self.api_key: return "error: missing API key"
        boundary = "----groqtypeboundary"
        fields = {"model": model, "language": language, "response_format": "json", "temperature": "0"}
        body = bytearray()
        for name, value in fields.items():
            body.extend(f"--{boundary}\r\n".encode())
            body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            body.extend(str(value).encode())
            body.extend(b"\r\n")
        with open(audio_path, "rb") as f:
            audio = f.read()
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(b'Content-Disposition: form-data; name="file"; filename="speech.wav"\r\n')
        body.extend(b"Content-Type: audio/wav\r\n\r\n")
        body.extend(audio)
        body.extend(b"\r\n")
        body.extend(f"--{boundary}--\r\n".encode())
        req = request.Request("https://api.groq.com/openai/v1/audio/transcriptions", data=bytes(body),
            headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": f"multipart/form-data; boundary={boundary}", "User-Agent": "GroqType/0.1", "Accept": "application/json"},
            method="POST")
        try:
            with request.urlopen(req, timeout=10) as res:
                data = json.loads(res.read().decode())
                return data.get("text", "")
        except Exception as e:
            return f"error: {e}"

    def transcribe_batch(self, audio_path: str, model: str, language: str) -> str:
        return self._call_api(audio_path, model, language)

    def transcribe_stream(self, audio_data, model: str, language: str) -> str:
        import tempfile
        import soundfile as sf
        fd, path = tempfile.mkstemp(prefix="groqtype-rolling-", suffix=".wav")
        os.close(fd)
        sf.write(path, audio_data, 16000) # Assuming 16k
        try:
            return self._call_api(path, model, language)
        finally:
            os.remove(path)
