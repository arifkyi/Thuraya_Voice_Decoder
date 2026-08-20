# Thuraya GMR-1 Voice Call to MP3

**Author:** Rifky The Cyber (@RifkyTheCyber)
**Brand:** Spectran Labs
**Companion to:** the Thuraya BCCH/CCCH interception guide (same osmo-gmr setup)

Decode and decrypt an encrypted Thuraya (GMR-1) satellite phone voice call down to
listenable audio, then export **MP3** if `ffmpeg` is installed, or fall back to **WAV**
if it is not. Same conditional-output behaviour as the Iridium `export_voc.sh` workflow.

---

## Pipeline

```
cfile (BCCH, ARFCN 267) ─┐
cfile (TCH,  ARFCN 268) ─┼─► gmr1_rx ──► AMBE frames (hex on stderr)
Kc (16 hex chars) ───────┘     │
                               ▼
                        extract frame0/frame1 hex ──► speech.dat (raw 10-byte AMBE frames)
                               │
                               ▼
                        gmr1_ambe_decode ──► WAV (8 kHz / 16-bit / mono)
                               │
                               ▼
                        ffmpeg present?  ── yes ──► MP3
                                         └─ no  ──► keep WAV
```

The `thuraya_voice_export.sh` script at the bottom runs this whole chain in one shot.

---

## What you need

- **osmo-gmr built from the `sylvain/live` branch.** That branch already ships
  `gmr1_ambe_decode` and the AMBE codec (`src/codec/ambe.c`) in `bin_PROGRAMS`, so it is a
  superset of `master`. You do **not** need to switch to `master` and you do not need to
  rebuild anything for the codec.
- **No GNU Radio required for decoding.** GNU Radio (the `gmr-env` conda) is only used by
  the live SDR capture script `gmr1_rx_sdr.py`. Decoding pre-captured cfiles never touches
  it. Do not even activate the conda env for this.
- **Runtime libraries:** `libosmocore`, `libosmodsp`, `fftw3f`. If your osmo-gmr build
  already succeeded and the binaries run, these are all present. (`libosmodsp` is the one
  that is not in stock Ubuntu apt and is built from source; if you got this far, you already
  have it.)
- **ffmpeg is optional.** With it you get MP3, without it you get WAV.

Quick confirmation that the codec binary is built and runs:

```bash
cd ~/Desktop/osmo-gmr
ls -la ./src/gmr1_rx ./src/gmr1_ambe_decode
printf '' | ./src/gmr1_ambe_decode - /tmp/ambe_test.wav && wc -c < /tmp/ambe_test.wav   # expect 44
```

`44` is a bare WAV header, which proves the vocoder links and runs (the tool creates the
output file itself, you do not supply it).

---

## Example data (voice call)

From the osmocom **Example_Data** wiki (open in a browser, the page is behind anti-bot
protection):

| File | Role | ARFCN |
|------|------|-------|
| `tnt-call-267-93600.cfile` | BCCH / control carrier | 267 (1541.344 MHz band) |
| `tnt-call-268-93600.cfile` | TCH / traffic carrier  | 268 |
| **Kc** | `ebc34fcbd572466c` | 16 hex chars |

The `93600` in the filename is the per-channel sample rate (4 samples/symbol x 23.4 ksym/s),
which is why the decoder runs with `sps = 4`.

### Use the 16-character Kc

A GMR-1 Kc is 64 bits, that is 8 bytes, that is always **16 hex characters**. The wiki lists
the correct value, `ebc34fcbd572466c`. A **15-character** variant, `ebc34fcbd572466`, is only
one hex digit short and appears in an old 2020 mailing-list post (and in some guides copied
from it); it is not the wiki value. Use the 16-character wiki value.

The truncated version parses to a wrong final byte, produces the wrong A5-GMR-1 keystream,
and decodes to **noise with no error message**. Always use `ebc34fcbd572466c`.

The files arrive bz2-compressed, so decompress first:

```bash
bunzip2 tnt-call-267-93600.cfile.bz2 tnt-call-268-93600.cfile.bz2
```

---

## Two things about how gmr1_rx really works

**1. gmr1_rx does not write `.dat` files.** For each TCH3 speech burst it decrypts with the
Kc, decodes the two 10-byte AMBE frames, and prints them as hex on **stderr**:

```
frame0=2c4ef86e4e5a03f24556
frame1=2fbf754179db626a52a9
```

There is no `speech_*.dat` on disk. To feed `gmr1_ambe_decode` you capture that stderr, pull
the `frame0=`/`frame1=` hex in order, and pack it into a raw `.dat` at 10 bytes per frame.
The export script does exactly this.

**2. You need both cfiles, in order: BCCH first, TCH second.** gmr1_rx walks the BCCH
carrier to lock FCCH, derive the frame number (FN), and read the immediate assignment that
configures the TCH3 receiver. The voice bursts are then read from the TCH carrier. Crucially,
A5-GMR-1 keys its keystream on the FN (`gmr1_a5(kc, fn, ...)`), and the FN only exists because
the BCCH gave you sync. So you cannot decode voice from the TCH file alone, and the argument
order is not optional.

---

## Manual steps

```bash
cd ~/Desktop/osmo-gmr

# 1. decode + decrypt, capturing stderr to a log
./src/gmr1_rx 4 tnt-call-267-93600.cfile tnt-call-268-93600.cfile ebc34fcbd572466c 2> /tmp/gmr1_call.log

# 2. sanity check
grep -c 'TCH3'        /tmp/gmr1_call.log      # number of speech bursts
grep -c '^frame[01]=' /tmp/gmr1_call.log      # number of AMBE frames recovered
grep 'conv=' /tmp/gmr1_call.log | head        # want conv=  0,  0  (clean decrypt)

# 3. extract AMBE frames -> speech.dat
python3 - <<'PY'
import re
raw = open('/tmp/gmr1_call.log').read()
frames = [h for h in re.findall(r'^frame[01]=([0-9a-fA-F]+)', raw, re.MULTILINE) if len(h)==20]
open('/tmp/speech.dat','wb').write(b''.join(bytes.fromhex(h) for h in frames))
print(f"frames: {len(frames)} | audio: {len(frames)*160/8000:.1f}s")
PY

# 4. AMBE -> WAV
./src/gmr1_ambe_decode /tmp/speech.dat /tmp/thuraya_call.wav

# 5. WAV -> MP3 (if ffmpeg present)
ffmpeg -y -i /tmp/thuraya_call.wav -codec:a libmp3lame -b:a 128k /tmp/thuraya_call.mp3
```

**Sanity tell:** `conv=  0,  0` on the frames means the convolutional decoder corrected zero
bit errors, which is the signature of a clean decrypt. A wrong or truncated Kc makes `conv`
jump around and the audio comes out as noise. A full clean decode of the example call yields
about 450 AMBE frames, roughly 9 seconds, and a WAV near 144,044 bytes.

---

## One-shot script: thuraya_voice_export.sh

Mirrors `export_voc.sh`: detects `ffmpeg` and outputs MP3 when present, WAV otherwise.

```bash
./thuraya_voice_export.sh <bcch.cfile> <tch.cfile> <Kc-16hex> [output_basename] [sps]

# example:
./thuraya_voice_export.sh tnt-call-267-93600.cfile tnt-call-268-93600.cfile \
                          ebc34fcbd572466c thuraya_call 4
```

The osmo-gmr directory defaults to `~/Desktop/osmo-gmr`; override with
`OSMO_GMR_DIR=/path/to/osmo-gmr ./thuraya_voice_export.sh ...`. The full script is shipped
alongside this README.

---

## Control-plane example (location update)

The voice call above is the main event. There is a second example on the same wiki that
decrypts a **location update** instead of a voice call. It produces no audio, it produces
**signalling**, so it is the better one to show on screen: you can freeze the encrypted frame,
apply the Kc, and watch the exact same frame turn into a readable Mobility Management message.

| File | Role |
|------|------|
| `tnt-locupd-267-93600.cfile` | BCCH / control carrier |
| `tnt-locupd-268-93600.cfile` | TCH / traffic carrier |
| **Kc** | `eb9c4d2b0d027131` (16 hex chars, already correct on the wiki) |

This path stops at `gmr1_rx` plus Wireshark. There is no AMBE / WAV / MP3 stage.

```bash
cd ~/Desktop/osmo-gmr
bunzip2 tnt-locupd-267-93600.cfile.bz2 tnt-locupd-268-93600.cfile.bz2   # if still compressed

# watch the decrypted signalling live (separate terminal)
sudo tshark -i lo -f 'port 4729' -Y 'gsm_a.dtap' -V

# decode + decrypt (BCCH first, TCH second, then the Kc)
./src/gmr1_rx 4 tnt-locupd-267-93600.cfile tnt-locupd-268-93600.cfile eb9c4d2b0d027131
```

**What the Kc actually buys you.** The cipher boundary is the **Ciphering Mode Command**.
Everything before it is sent in the clear and is readable with or without the Kc; everything
after it is encrypted and only becomes readable once the Kc is applied.

- Readable in **both** (clear-text, Kc changes nothing): BCCH System Information, CCCH paging
  (which carries TMSIs in the clear, so decryption does not "reveal" those), Immediate
  Assignment, the Authentication Request, and the Ciphering Mode Command itself.
- Readable **only after decryption**: the **Location Updating Accept**, carrying the Location
  Area Identification (in this sample MCC 901 / MNC 05 Thuraya RMSS / LAC 1312), and an **MM
  Information** message pushing the network name and time zone. In the undeciphered capture
  those two frames dead-end at `gmr1.dtap` (Wireshark sees a DTAP frame but cannot read
  inside it); with the Kc they continue to `gsm_a.dtap` and dissect fully.

**Two ways to see it.** The wiki also ships ready-made pcaps, `tnt-locupd.pcap` (encrypted)
and `tnt-locupd-deciphered.pcap` (Sylvain's pre-decrypted version). So a viewer can either
decode the cfiles themselves with the Kc using the command above, or simply open the
deciphered pcap in Wireshark. State on camera which one you are demonstrating, so nobody
thinks the pcap decrypted itself.

---

## Managing expectations (honesty for the video)

The example capture is **partially redacted by Sylvain Munaut for privacy**: some bursts are
zeroed. In practice you still get intelligible fragments (in the example call you can hear
"halo halo" and dial-pad tones), but expect a stretch or two that drops or garbles rather
than one seamless conversation. Narrate that honestly. The audio is telephone-quality 8 kHz
mono through a reimplemented AMBE vocoder, so it sounds slightly robotic. Sylvain's own words:
"not the same audio quality as the original, but perfectly intelligible."

The honest story of the demo is watching the A5-GMR-1 decryption and TCH3 decode chain work,
with the recovered audio as the payoff.

---

## Troubleshooting

| Problem | Cause / fix |
|---------|-------------|
| `gmr1_ambe_decode` not found | Build osmo-gmr from `sylvain/live` (its `bin_PROGRAMS` includes the decoder). |
| Audio is noise, `conv` not `0,0` | Wrong or truncated Kc. Use the 16-char `ebc34fcbd572466c`. |
| No `frame0=`/`frame1=` lines in the log | Wrong cfile order (BCCH must be first), missing TCH file, or wrong `sps`. |
| `gmr1_ambe_decode` stops early, prints `[!] codec error` | The stock decoder halts on the first frame it cannot decode. A zeroed/redacted burst can trigger this. A frame-tolerant variant (decode each frame independently, substitute 20 ms silence on error) recovers everything after the bad frame. |
| WAV is silent or scrambled | Wrong Kc, or that segment was zeroed in the sample. |
| `.cfile` not found | Still compressed. Run `bunzip2 *.cfile.bz2`. |

---

## References

- osmo-gmr: https://github.com/osmocom/osmo-gmr
- Live branch (`gmr1_rx_live`): https://github.com/osmocom/osmo-gmr/tree/sylvain/live
- Example data + Kc (Sylvain Munaut): https://osmocom.org/projects/gmr/wiki/Example_Data
- A5-GMR-1 cipher (A5/2 lineage): https://projects.osmocom.org/projects/gmr/wiki/A5-GMR-1
- Provenance + redaction note (Sylvain, mailing list): https://www.mail-archive.com/gmr@lists.osmocom.org/msg00031.html
- osmo-gmr / voice codec talk, 31C3 (2014): "osmo-gmr: What's up with sat-phones?"
- Driessen et al., GMR cipher analysis: https://eprint.iacr.org/2012/051.pdf

---

## Disclaimer

This research is for educational and security-research purposes only. The audio pipeline is
demonstrated on the osmocom **public example data**, which the author deliberately redacted
for privacy. Intercepting private communications without authorisation may be illegal in your
jurisdiction. Always comply with local law.

---

**Rifky The Cyber** | YouTube: @RifkyTheCyber | GitHub: arifkyi | Brand: Spectran Labs
