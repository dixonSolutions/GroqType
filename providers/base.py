from abc import ABC, abstractmethod

class BaseProvider(ABC):
    @abstractmethod
    def transcribe_batch(self, audio_path: str, model: str, language: str) -> str:
        """Transcribe a full file."""
        pass

    @abstractmethod
    def transcribe_stream(self, audio_data, model: str, language: str) -> str:
        """Transcribe a chunk of audio."""
        pass
