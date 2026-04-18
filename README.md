# kria iii

4 track midi step sequencer for [monome grid](https://monome.org/docs/grid/) running on the [iii scripting environment](https://github.com/monome/iii).

based on the original [ansible kria](https://monome.org/docs/ansible/kria/) by monome, adapted for midi output with additional features.

## files

- **kria_iii.lua** — the script to upload to iii
- **kria_iii_manual.html** — open in a browser for the full manual
- **kria_iii_commented.lua** — fully annotated reading reference (do not upload — exceeds iii source buffer)


## features

- 4 tracks, 16 steps, 4 parameter pages: trigger, note, octave, duration
- trigger ratcheting — up to 5 individually toggled sub-triggers per step
- alternate note — second note sequence with its own loop and clock division
- per-track loop with wrap-around, 5 direction modes, clock division
- per-step probability and note quantization mode
- 16 scale presets with editable intervals, live micro-adjust
- 16 pattern slots with flash persistence and quantized cueing
- internal tempo control (30-300bpm) and external MIDI clock input
- configurable MIDI channel per track, MIDI clock output

## requirements

- monome grid 128
- iii scripting environment

## usage

upload `kria_iii.lua` via the iii web interface. See `kria_iii_manual.html` for full documentation.

## version

v1.1.0
