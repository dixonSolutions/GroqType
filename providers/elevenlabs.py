from .base import BaseProvider

class ElevenLabsProvider(BaseProvider):
    def __init__(self, api_key: str):
        self.api_key = api_key

    def transcribe_batch(self, audio_path: str, model: str, language: str) -> str:
        # TODO: Implement ElevenLabs Scribe batch API
        return "error: ElevenLabs batch not yet implemented"

    def transcribe_stream(self, audio_data, model: str, language: str) -> str:
        # TODO: Implement ElevenLabs Scribe streaming API
        return "error: ElevenLabs streaming not yet implemented"
