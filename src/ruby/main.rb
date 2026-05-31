require 'js'
require 'set'
require 'web_component'
require 'midi_sender'
require 'audio_engine'
require 'ctrl_group'   # registers <dim-ctrl> and <vol-ctrl>
require 'kebab_menu'   # registers <kebab-menu>
require 'midi_out_ctrl' # registers <midi-out-ctrl>
require 'audio_out_ctrl' # registers <audio-out-ctrl>
require 'pad_grid'     # triggers PadGrid.register("pad-grid") at load time

# Global MIDI sender — used by PadGrid event handlers and JS control wire-up
$midi_sender = MidiSender.new

# Global Audio engine — local synthesis, parallel to MIDI output
$ctx = JS.eval("return window.App.audioCtx;")
$audio_engine = AudioEngine.new($ctx)

puts "[main] Ruby boot complete. <pad-grid> registered."
