from .groq import GroqProvider
from .elevenlabs import ElevenLabsProvider

PROVIDERS = {
    "groq": GroqProvider,
    "elevenlabs": ElevenLabsProvider,
}

def get_provider(name, api_key):
    provider_class = PROVIDERS.get(name)
    if not provider_class:
        raise ValueError(f"Unknown provider: {name}")
    return provider_class(api_key)
