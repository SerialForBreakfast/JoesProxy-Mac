"""Print peak and average bps for an authored TS variant and selectable audio."""
from math import ceil
from pathlib import Path
import re
import sys


def rates(playlist):
    segments = []
    for line in playlist.read_text().splitlines():
        if line.startswith("#EXT-X-TARGETDURATION:"):
            target = int(line.split(":")[1])
        elif line.startswith("#EXTINF:"):
            duration = float(line.split(":")[1].split(",")[0])
        elif line and not line.startswith("#"):
            segments.append((duration, (playlist.parent / line).stat().st_size * 8))
    # RFC 8216 peak windows contain between 0.5 and 1.5 target durations.
    peak = 0
    for start in range(len(segments)):
        seconds = bits = 0
        for duration, size in segments[start:]:
            seconds += duration
            bits += size
            if seconds > 1.5 * target:
                break
            if seconds >= 0.5 * target:
                peak = max(peak, bits / seconds)
    if not peak:
        raise ValueError(f"No peak-rate window in {playlist}")
    return peak, sum(bits for _, bits in segments) / sum(t for t, _ in segments)


def update(profile):
    master = profile / "master.m3u8"
    lines = master.read_text().splitlines()
    # These synthetic TS fixtures use a single external audio group.
    audio = [rates(profile / re.search(r'URI="([^"]+)"', line)[1])
             for line in lines if line.startswith("#EXT-X-MEDIA:TYPE=AUDIO,")]
    for index, line in enumerate(lines):
        if line.startswith("#EXT-X-STREAM-INF:"):
            video = rates(profile / lines[index + 1])
            peak, mean = [ceil(v + max(track[i] for track in audio)) for i, v in enumerate(video)]
            lines[index] = re.sub(r'BANDWIDTH=\d+,AVERAGE-BANDWIDTH=\d+',
                                  f'BANDWIDTH={peak},AVERAGE-BANDWIDTH={mean}', line)
    master.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    for directory in sys.argv[1:]:
        update(Path(directory))
