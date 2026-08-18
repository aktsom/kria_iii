# kria iii

4 track midi step sequencer for [monome grid](https://monome.org/docs/grid/) running on the [iii scripting environment](https://github.com/monome/iii).

based on the original [ansible kria](https://monome.org/docs/ansible/kria/) by monome, adapted for midi output with additional features. consider this a kria lite version

## files

- **kria_iii.lua** 
- **kria_iii_manual.html** - open in a browser for the full manual
   https://aktsom.github.io/kria_iii/kria_iii_manual.html


## features

- 4 tracks, 16 steps, parameter pages: trigger, note, octave, duration, ratchet, alt note, velocity.
- trigger ratcheting - up to 5 individually toggled sub-triggers per step
- alternate note - second note sequence with its own loop and clock division
- per-track loop with wrap-around, 5 direction modes, clock division
- per-step probability and note quantization mode
- 16 scale presets with editable intervals, live adjust
- 16 pattern slots with flash persistence and quantized cueing
- internal tempo control (30-300bpm) and external MIDI clock input
- configurable MIDI channel per track, MIDI clock output
- consider this a kria lite version. missing features are glide page, meta-patterns, per-parameter clock divisions, division cueing, division sync modes

## what's new in v1.6.3

* **memory usage reduced** - addresses out-of-memory errors some users hit when uploading or while running. all per-step sequence data is now bit-packed into a single flat integer array (replacing 40 lua tables), constant tables are packed into byte strings or computed on the fly, duplicated code paths are consolidated, the pattern-save path allocates far less, and garbage collection runs at the load-time choke points. saved patterns are fully compatible. if an upload still fails with `-- out of memory!`, power-cycle the device and upload again with a fresh boot

## what's new in v1.6.1

* **midi clock output fix** - kria iii now sends correct midi clock (24ppqn). previously sent 1 pulse per step (4ppqn), causing connected devices to display 1/6 the intended tempo. also fixes transport start/stop not working when connected via usb due to midi loopback

## what's new in v1.6.0

* **note length redesign** - note length is measured in track steps. step 9  = one step (×1 default) - the note ends as the next step fires. steps 1-8 = fractions of one step. steps 10-16 = 2, 4, 8, 10, 12, 14, 16 steps. tempo and time division affect how long a step is in real time, but the multiplier always means that many steps. for a 16-step loop: ×16 = one full pass, ×8 = half, ×4 = quarter. for a shorter loop like the default 6-step, ×6 would be one pass, ×16 would be nearly three passes.
* **sustain mode removed** - replaced by ×16 as the natural top of the range

## what's new in v1.5.0

* **note tie** - config toggle (step 9, row 8). when on, sends note-on before note-off on consecutive steps, triggering legato on connected instruments
* **ratchet silent steps** - fully silent steps are now possible: clear all active slots to leave a step with no sub-triggers. rests display dimmer for cleaner visual distinction
* **alt note independent loop** - when loop sync and note sync are both off, holding loop mod on the alt note page stays on the alt note page. press any two steps across rows 1–7 to set an independent loop brace for the alt note sequence
* **config page toggle** - config page is now a toggle (press to open, press again to close). config button blinks when open
* **trigger page note fix** - activating a trigger no longer resets that step's note value to the root
* **scale copy auto-switch** - copying a scale preset to another slot now immediately switches to and applies the destination slot

## what's new in v1.4.1

* **track clear expanded** - holding a track button on the trigger page now resets all parameters (notes, octave, note length, velocity, probability, ratchet) in addition to triggers
* **stability improvements** - removed dead code, cleaner render loop, reduced chance of occasional led flicker
* **nav row muted indicator** - muted tracks now show as solid dim instead of blinking
* **trigger page playhead** - slightly improved contrast between active steps and the playhead
* **manual** - duration page renamed to note length, time page renamed to tempo

## what's new in v1.4.0

* **probability expanded to 5 rows** - 100%/ 75% / 50% / 25% / 0%. now deterministic: each level follows a fixed 4-loop cycle rather than random rolls, so patterns are predictable
* **C,D,E,F,G,A,B root selection with sharps** - scale page root now uses a piano-style layout. press a root step for natural, press again to sharpen (C# D# F# G# A#). sharp root blinks while active
* **sharp root shortcut** - hold step 16 on the scale page + press any root key to toggle sharp immediately, without double-tapping. useful when changing root live
* **velocity page** - per-step velocity control added as a second-press sub-page on the octave button (blinks when active)
* **duration page** - improved behaviour
* **loop snap** - config toggle (step 14, row 3) for quantized loop setting. when on, a new loop is held as a pending snap and fires when a running track long enough to contain it completes a cycle, keeping loop changes in sync
* **pattern load feedback** - saved pattern slots now light up at the same moment as the load confirmation, making the visual feedback clear and instant
* **ui improvements** - cleaner visual feedback across pattern, navigation, and scale pages
* **cleaned up the manual** - should be easier to get through

## requirements

- designed for monome grid one (128)
- iii scripting environment

## usage

upload `kria_iii.lua` via the iii web interface. https://dessertplanet.github.io/web-diii/
 See `kria_iii_manual.html` for full documentation.

llm disclosure 

## version

v1.6.3
