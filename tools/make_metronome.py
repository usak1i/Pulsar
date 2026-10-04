#!/usr/bin/env python3
"""產生 120 BPM 的節拍器 WAV，當作遊戲的時序測試素材。

每拍一個 10ms 的 1kHz 短音，每四拍一次重音。
不是音樂，但它讓「note 有沒有對上拍子」可以用耳朵驗證。

用法：python3 tools/make_metronome.py
輸出：charts/01-metronome/audio.wav
"""
import math
import os
import struct
import wave

BPM = 120
BEATS = 64
SAMPLE_RATE = 44100
CLICK_SECONDS = 0.010
CLICK_HZ = 1000.0
OUT = os.path.join("charts", "01-metronome", "audio.wav")

seconds_per_beat = 60.0 / BPM
total_frames = int(SAMPLE_RATE * seconds_per_beat * BEATS)

frames = bytearray()
for n in range(total_frames):
    t = n / SAMPLE_RATE
    beat_index = int(t / seconds_per_beat)
    into_beat = t - beat_index * seconds_per_beat

    amp = 0.0
    if into_beat < CLICK_SECONDS:
        envelope = 1.0 - into_beat / CLICK_SECONDS
        gain = 0.9 if beat_index % 4 == 0 else 0.45
        amp = gain * envelope * math.sin(2 * math.pi * CLICK_HZ * into_beat)

    frames += struct.pack("<h", int(max(-1.0, min(1.0, amp)) * 32767))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with wave.open(OUT, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SAMPLE_RATE)
    w.writeframes(bytes(frames))

print(f"wrote {OUT}: {BEATS} beats @ {BPM} BPM = {total_frames / SAMPLE_RATE:.1f}s")
