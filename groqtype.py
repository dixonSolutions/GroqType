#!/usr/bin/env python3
import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import threading
import re
from pathlib import Path
from urllib import request, error
from collections import deque
from difflib import SequenceMatcher

def get_config_path():
    if os.geteuid() == 0:
        return Path("/etc/groqtype/config.json")
    return Path.home() / ".config" / "groqtype" / "config.json"

CONFIG_PATH = get_config_path()

DEFAULT_CONFIG = {
    "api_key": "",
    "model": "whisper-large-v3-turbo",
    "language": "en",
    "transcribe_mode": "batch",
    "output_mode": "paste",
    "paste_command": ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
    "paste_delay_ms": 80,
    "sample_rate": 16000,
    "hotkey": "f24",
    "stream_window_sec": 6.0,
    "stream_step_sec": 0.7,
    "ydotool_socket": None,
}

def get_ydotool_env():
    cfg = load_config()
    env = os.environ.copy()
    if cfg.get("ydotool_socket"):
        env["YDOTOOL_SOCKET"] = cfg["ydotool_socket"]
    return env

def die(msg: str):
    print(f"groqtype: {msg}", file=sys.stderr)
    sys.exit(1)

def ensure_dirs():
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)

from providers.registry import get_provider

def load_config():
    ensure_dirs()
    if not CONFIG_PATH.exists():
        save_config(DEFAULT_CONFIG)
    with CONFIG_PATH.open("r") as f:
        cfg = json.load(f)
    
    # Migration
    if "model" in cfg and "provider" not in cfg:
        cfg["provider"] = "groq"
        cfg["streaming_model"] = cfg.pop("model")
        cfg["batch_model"] = cfg["streaming_model"]
        save_config(cfg)
        
    return {**DEFAULT_CONFIG, **cfg}

def save_config(cfg):
    ensure_dirs()
    with CONFIG_PATH.open("w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_PATH, 0o600)

class GroqTypeDaemon:
    def __init__(self):
        global sd, sf, np, torch, load_silero_vad, VADIterator
        import sounddevice as sd
        import soundfile as sf
        import numpy as np
        import torch
        from silero_vad import load_silero_vad, VADIterator

        self.cfg = load_config()
        self.provider = get_provider(self.cfg["provider"], self.cfg.get("api_key") or os.environ.get("GROQ_API_KEY"))
        self.frames = deque()
        self.frames_lock = threading.Lock()
        
        self.stream = None
        self.is_recording = False
        self.session_words = []
        self.stop_event = threading.Event()
        self.transcribe_thread = None
        self.output_lock = threading.Lock()
        
    def audio_callback(self, indata, frames, time, status):
        if self.is_recording:
             with self.frames_lock:
                self.frames.append(indata.copy())

    def start_recording(self):
        if self.is_recording:
            return "already recording"

        with self.frames_lock:
            self.frames.clear()
        
        self.session_words = []
        self.stop_event.clear()
        
        self.stream = sd.InputStream(
            samplerate=self.cfg["sample_rate"],
            channels=1,
            dtype="float32",
            callback=self.audio_callback,
        )
        self.stream.start()
        self.is_recording = True
        
        if self.cfg.get("transcribe_mode") == "stream":
            self.transcribe_thread = threading.Thread(target=self.stream_loop)
            self.transcribe_thread.start()
            
    def stop_recording(self):
        if not self.is_recording:
            return "not recording"

        self.stop_event.set()
        if self.transcribe_thread:
            self.transcribe_thread.join()
            self.transcribe_thread = None

        self.stream.stop()
        self.stream.close()
        self.is_recording = False

        with self.frames_lock:
            if not self.frames:
                return "no audio recorded"
            audio = np.concatenate(list(self.frames), axis=0)

        fd, path = tempfile.mkstemp(prefix="groqtype-", suffix=".wav")
        os.close(fd)
        sf.write(path, audio, self.cfg["sample_rate"])
        text = self.provider.transcribe_batch(path, self.cfg["batch_model"], self.cfg["language"]).strip()
        os.remove(path)

        if text.startswith("error:"):
            return text

        if self.cfg.get("transcribe_mode") == "stream":
            self.sync_ui_text(text, is_final=True)
            return f"stream finished: {' '.join(self.session_words)}"
        else:
            self.output_result(text)
            return f"batch finished: {text}"

    def sync_ui_text(self, hypothesis, is_final=False):
        """
        Precise alignment between session history and new rolling window.
        Uses a mutable tail to prevent stuttering and duplication.
        """
        hypothesis = re.sub(r' +', ' ', hypothesis).strip()
        hypo_words = hypothesis.split()
        if not hypo_words and not self.session_words:
            return

        with self.output_lock:
            # 1. FIND BEST OVERLAP (Suffix-Prefix Matching)
            # Find the longest suffix of session_words that matches a prefix of hypo_words.
            best_overlap_len = 0
            best_session_start = len(self.session_words)
            
            # Search last 30 words for performance and stability
            lookback = 30
            search_start = max(0, len(self.session_words) - lookback)
            
            for i in range(search_start, len(self.session_words)):
                session_suffix = self.session_words[i:]
                match_limit = min(len(session_suffix), len(hypo_words))
                
                match_count = 0
                for s_w, h_w in zip(session_suffix, hypo_words):
                    if s_w.lower() == h_w.lower():
                        match_count += 1
                    else:
                        break
                
                if match_count > best_overlap_len:
                    best_overlap_len = match_count
                    best_session_start = i
            
            # 2. RECONCILE VIA MUTABLE TAIL
            # Everything after the common prefix is the "mutable tail".
            diverge_session_idx = best_session_start + best_overlap_len
            words_to_delete = len(self.session_words) - diverge_session_idx
            words_to_add = hypo_words[best_overlap_len:]
            
            # Apply changes if necessary
            if words_to_delete > 0 or words_to_add:
                self.execute_ui_reconciliation(words_to_delete, words_to_add)
                self.session_words = self.session_words[:diverge_session_idx]
                self.session_words.extend(words_to_add)

    def execute_ui_reconciliation(self, delete_count, add_words):
        """Precision typing and backspacing."""
        chars_to_del = 0
        if delete_count > 0:
            words_to_rm = self.session_words[-delete_count:]
            for w in words_to_rm:
                chars_to_del += len(w) + 1 # char count + the space we typed
        
        try:
            # 1. BACKSPACE
            if chars_to_del > 0:
                # Key 14 is Backspace. 14:1 is down, 14:0 is up.
                subprocess.run(["ydotool", "key"] + ["14:1", "14:0"] * chars_to_del, check=True, env=get_ydotool_env())
            
            # 2. TYPE
            if add_words:
                text_to_type = " ".join(add_words)
                
                # If we aren't at the start, and we didn't just backspace a space,
                # we usually need a leading space. 
                # But our session_words logic includes a space AFTER every word.
                # So if we have a session AND we didn't delete everything, prefix with space.
                prefix = ""
                if self.session_words and delete_count < len(self.session_words):
                    prefix = " "
                
                # Type the content plus a trailing space to separate it from the NEXT chunk
                subprocess.run(["ydotool", "type", prefix + text_to_type], check=True, env=get_ydotool_env())
        except subprocess.CalledProcessError:
            pass

    def output_result(self, text):
        o_mode = self.cfg.get("output_mode", "paste")
        if o_mode == "copy":
            self.copy_text(text)
        elif o_mode == "type":
            subprocess.run(["ydotool", "type", text], check=True, env=get_ydotool_env())
        elif o_mode == "paste":
            self.copy_text(text)
            time.sleep(self.cfg["paste_delay_ms"] / 1000)
            self.paste()

    def stream_loop(self):
        step_sec = self.cfg.get("stream_step_sec", 0.7)
        window_sec = self.cfg.get("stream_window_sec", 6.0)
        window_samples = int(self.cfg["sample_rate"] * window_sec)
        
        while not self.stop_event.is_set():
            time.sleep(step_sec)
            with self.frames_lock:
                if not self.frames: continue
                current_audio = np.concatenate(list(self.frames), axis=0)
            
            process_audio = current_audio[-window_samples:] if len(current_audio) > window_samples else current_audio
            if len(process_audio) < int(self.cfg["sample_rate"] * 0.5): continue
            
            threading.Thread(target=self.async_transcribe, args=(process_audio,)).start()

    def async_transcribe(self, audio_data):
        text = self.provider.transcribe_stream(audio_data, self.cfg["streaming_model"], self.cfg["language"]).strip()
        
        if text and not text.startswith("error:"):
            self.sync_ui_text(text)

    def copy_text(self, text):
        subprocess.run(["wl-copy"], input=text.encode(), check=True)

    def paste(self):
        cmd = self.cfg.get("paste_command")
        try:
            subprocess.run(cmd, check=True, env=get_ydotool_env())
            return None
        except subprocess.CalledProcessError as e:
            return f"error: paste failed: {e}"

    def monitor(self):
        hotkey = self.cfg.get("hotkey", "f24")
        recording = False
        print(f"Monitoring hotkey: {hotkey}", flush=True)
        proc = subprocess.Popen(["keyd", "monitor"], stdout=subprocess.PIPE, text=True)
        for line in iter(proc.stdout.readline, ""):
            line = line.strip()
            if not line: continue
            if hotkey in line:
                if "down" in line and not recording:
                    recording = True
                    print(f"Hotkey {hotkey} DOWN -> {self.start_recording()}", flush=True)
                elif "up" in line and recording:
                    recording = False
                    print(f"Hotkey {hotkey} UP -> {self.stop_recording()}", flush=True)
        proc.wait()

    def run(self):
        ensure_dirs()
        self.monitor()

def cmd_config(args):
    cfg = load_config()
    if args.key == "api-key": cfg["api_key"] = args.value
    elif args.key == "provider": cfg["provider"] = args.value
    elif args.key == "streaming-model": cfg["streaming_model"] = args.value
    elif args.key == "batch-model": cfg["batch_model"] = args.value
    elif args.key == "language": cfg["language"] = args.value
    elif args.key == "paste-delay-ms": cfg["paste_delay_ms"] = int(args.value)
    elif args.key == "hotkey": cfg["hotkey"] = args.value
    elif args.key == "transcribe-mode":
        if args.value not in ["batch", "stream"]: die("transcribe-mode must be: batch or stream")
        cfg["transcribe_mode"] = args.value
    elif args.key == "output-mode":
        if args.value not in ["paste", "type", "copy"]: die("output-mode must be: paste, type, or copy")
        cfg["output_mode"] = args.value
    elif args.key == "stream-window-sec": cfg["stream_window_sec"] = float(args.value)
    elif args.key == "stream-step-sec": cfg["stream_step_sec"] = float(args.value)
    elif args.key == "ydotool-socket": cfg["ydotool_socket"] = args.value
    else: die("valid config keys: api-key, provider, streaming-model, batch-model, language, paste-delay-ms, hotkey, transcribe-mode, output-mode, stream-window-sec, stream-step-sec, ydotool-socket")
    save_config(cfg)
    print(f"set {args.key} in {CONFIG_PATH}")

def cmd_config_show(_args):
    cfg = load_config()
    safe = dict(cfg)
    if safe.get("api_key"): safe["api_key"] = safe["api_key"][:8] + "..."
    print(f"Configuration from {CONFIG_PATH}:")
    print(json.dumps(safe, indent=2))

def main():
    parser = argparse.ArgumentParser(prog="groqtype")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("daemon")
    c = sub.add_parser("config")
    c.add_argument("key")
    c.add_argument("value")
    sub.add_parser("config-show")
    args = parser.parse_args()
    if args.cmd == "daemon": GroqTypeDaemon().run()
    elif args.cmd == "config": cmd_config(args)
    elif args.cmd == "config-show": cmd_config_show(args)

if __name__ == "__main__":
    main()
