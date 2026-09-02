#!/usr/bin/env python3

import argparse
from pathlib import Path

import numpy as np
import soundfile as sf
from nara_wpe.utils import istft, stft
from nara_wpe.wpe import wpe


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Offline NARA-WPE dereverberation for a PCM WAV file.")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--shift", type=int, default=128)
    parser.add_argument("--taps", type=int, default=10)
    parser.add_argument("--delay", type=int, default=3)
    parser.add_argument("--iterations", type=int, default=3)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    audio, sample_rate = sf.read(args.input, always_2d=True, dtype="float64")
    if audio.size == 0 or sample_rate <= 0:
        raise ValueError("Input audio is empty or has an invalid sample rate.")

    spectrum = stft(audio.T, size=args.size, shift=args.shift).transpose(2, 0, 1)
    enhanced = wpe(
        spectrum,
        taps=args.taps,
        delay=args.delay,
        iterations=args.iterations,
        statistics_mode="full",
    ).transpose(1, 2, 0)
    restored = istft(enhanced, size=args.size, shift=args.shift).T
    restored = restored[: audio.shape[0], : audio.shape[1]]
    if restored.shape != audio.shape:
        raise ValueError(f"Output shape {restored.shape} differs from input {audio.shape}.")
    if not np.isfinite(restored).all():
        raise ValueError("Dereverberation produced non-finite samples.")

    peak = float(np.max(np.abs(restored)))
    if peak > 0.999:
        restored *= 0.999 / peak
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sf.write(args.output, restored, sample_rate, subtype="PCM_16")
    print(
        f"NARA_WPE_DEREVERB_PASS sample_rate={sample_rate} "
        f"channels={audio.shape[1]} samples={audio.shape[0]} peak_before_limit={peak:.6f}"
    )


if __name__ == "__main__":
    main()
