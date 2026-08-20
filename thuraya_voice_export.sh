#!/bin/bash
# thuraya_voice_export.sh
# Decode + decrypt a Thuraya GMR-1 voice call to MP3 (or WAV if ffmpeg is missing).
#
# Pipeline:
#   cfile(BCCH) + cfile(TCH) + Kc
#     -> gmr1_rx            (A5-GMR-1 decrypt + TCH3 decode, AMBE frames printed as hex on stderr)
#     -> extract frames     (frame0=/frame1= hex  ->  raw 10-byte AMBE frames)
#     -> gmr1_ambe_decode   (AMBE  ->  8 kHz/16-bit/mono WAV)
#     -> ffmpeg             (WAV  ->  MP3, only if ffmpeg is installed)
#
# Usage:
#   ./thuraya_voice_export.sh <bcch.cfile> <tch.cfile> <Kc-16hex> [output_basename] [sps]
#
# Example (osmocom voice example data):
#   ./thuraya_voice_export.sh tnt-call-267-93600.cfile tnt-call-268-93600.cfile \
#                             ebc34fcbd572466c thuraya_call 4
#
# The osmo-gmr build directory defaults to ~/Desktop/osmo-gmr.
# Override it with:  OSMO_GMR_DIR=/path/to/osmo-gmr ./thuraya_voice_export.sh ...

set -euo pipefail

BCCH="${1:?Usage: $0 <bcch.cfile> <tch.cfile> <Kc-16hex> [output_basename] [sps]}"
TCH="${2:?Need the TCH cfile as argument 2}"
KC="${3:?Need the Kc (16 hex chars) as argument 3}"
OUT_BASE="${4:-thuraya_call}"
SPS="${5:-4}"

OSMO_GMR_DIR="${OSMO_GMR_DIR:-$HOME/Desktop/osmo-gmr}"
GMR1_RX="$OSMO_GMR_DIR/src/gmr1_rx"
AMBE_DECODE="$OSMO_GMR_DIR/src/gmr1_ambe_decode"

LOG="${OUT_BASE}.gmr1.log"      # full decoder stderr (keep for inspection / Wireshark story)
DAT="${OUT_BASE}.speech.dat"    # raw concatenated AMBE frames
WAV="${OUT_BASE}.wav"
MP3="${OUT_BASE}.mp3"

# --- sanity: binaries ---
for bin in "$GMR1_RX" "$AMBE_DECODE"; do
    if [ ! -x "$bin" ]; then
        echo "ERROR: not found or not executable: $bin"
        echo "       Build osmo-gmr from the sylvain/live branch, or set OSMO_GMR_DIR."
        exit 1
    fi
done

# --- sanity: input cfiles ---
for f in "$BCCH" "$TCH"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: cfile not found: $f"
        echo "       (Still compressed? Run: bunzip2 *.cfile.bz2)"
        exit 1
    fi
done

# --- sanity: Kc length. A5-GMR-1 Kc is 64 bits = 8 bytes = 16 hex chars. ---
if [ "${#KC}" -ne 16 ]; then
    echo "WARNING: Kc is ${#KC} hex chars, expected 16."
    echo "         A truncated Kc silently decodes to noise (wrong keystream)."
    echo "         The correct voice-call Kc is ebc34fcbd572466c."
fi

# --- ffmpeg detection (same pattern as export_voc.sh) ---
if command -v ffmpeg &>/dev/null; then
    USE_FFMPEG=1
    echo "ffmpeg detected      -> final output will be MP3"
else
    USE_FFMPEG=0
    echo "ffmpeg not found     -> final output will be WAV (install: sudo apt install ffmpeg)"
fi

# --- decode + decrypt ---
echo "[*] Decoding + decrypting  (BCCH=$BCCH  TCH=$TCH  sps=$SPS)"
"$GMR1_RX" "$SPS" "$BCCH" "$TCH" "$KC" 2> "$LOG" || true   # gmr1_rx may exit non-zero at EOF

BURSTS=$(grep -c 'TCH3' "$LOG" || true)
echo "    TCH3 speech bursts seen: ${BURSTS:-0}"

# --- extract AMBE frames from stderr (gmr1_rx does NOT write .dat itself) ---
echo "[*] Extracting AMBE frames from decoder output"
python3 - "$LOG" "$DAT" <<'PYEOF'
import re, sys
log, dat = sys.argv[1], sys.argv[2]
raw = open(log, 'r', errors='replace').read()
# Each TCH3 burst prints two 10-byte AMBE frames as hex: frame0=<20hex> / frame1=<20hex>
frames = re.findall(r'^frame[01]=([0-9a-fA-F]+)', raw, re.MULTILINE)
frames = [h for h in frames if len(h) == 20]        # 10 bytes each; drop anything malformed
data = b''.join(bytes.fromhex(h) for h in frames)
open(dat, 'wb').write(data)
secs = len(frames) * 160 / 8000.0                    # 160 samples per frame @ 8 kHz
print(f"    AMBE frames: {len(frames)} | bytes: {len(data)} | approx audio: {secs:.1f}s")
PYEOF

if [ ! -s "$DAT" ]; then
    echo "ERROR: no AMBE frames extracted."
    echo "       Check: cfile order (BCCH first, TCH second), the Kc, and sps ($SPS)."
    exit 1
fi

# --- AMBE -> WAV ---
echo "[*] Decoding AMBE -> WAV  ($WAV)"
"$AMBE_DECODE" "$DAT" "$WAV"
WAV_BYTES=$(wc -c < "$WAV" | tr -d ' ')
echo "    WAV size: ${WAV_BYTES} bytes"

# --- WAV -> MP3 if ffmpeg, else keep WAV ---
if [ "$USE_FFMPEG" -eq 1 ]; then
    echo "[*] Converting WAV -> MP3  ($MP3)"
    if ffmpeg -y -loglevel error -i "$WAV" -codec:a libmp3lame -b:a 128k "$MP3"; then
        echo "[+] Done: $MP3   (WAV kept as $WAV for editing)"
    else
        echo "[!] ffmpeg failed, keeping WAV: $WAV"
    fi
else
    echo "[+] Done: $WAV"
fi

echo "[i] Decoder log kept at: $LOG"
