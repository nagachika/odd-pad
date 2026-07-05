require 'js'
require 'json'
require 'synthesizer'

# One recorded note. step is the absolute position inside the loop in 1/32
# units, dur is a step count (>= 1). Pitch is kept in pad coordinates
# (x 0..8, y 0..8, oct -3..3, dim 3/4/5) so the note table edits map 1:1 to
# the pad grid; AudioEngine#freq_for converts to a frequency at play time.
SeqNote = Struct.new(:step, :dur, :x, :y, :oct, :dim, :vel) do
  def to_h_compact
    { s: step, d: dur, x: x, y: y, o: oct, m: dim, v: vel }
  end

  def self.from_h(h)
    new(h[:s].to_i, [h[:d].to_i, 1].max, h[:x].to_i, h[:y].to_i,
        h[:o].to_i, h[:m].to_i, h[:v].to_f)
  end
end

# Standalone step sequencer: 8 tracks x 16 loops (scenes shared by all
# tracks), each loop 1..8 bars at 1/32-note resolution. Playback goes through
# each track's own Synthesizer via the pooled schedule_note path; the pad's
# realtime MIDI behaviour is untouched.
class StepSequencer
  MAX_TRACKS = 8
  MAX_LOOPS  = 16
  MAX_BARS   = 8
  # Time signature is variable internally; the UI only exposes 4/4.
  BEATS_PER_BAR  = 4
  STEPS_PER_BEAT = 8 # 1/32-note resolution
  STORAGE_KEY = "odd-pad.seq.v1"

  SCHEDULE_AHEAD_SEC = 0.1
  LOOKAHEAD_MS = 25.0

  attr_reader :bpm, :is_playing, :recording, :play_mode, :quantize, :metronome
  attr_reader :current_loop_index, :selected_track, :song, :loops, :tracks
  attr_accessor :on_position # proc called with a label string on each beat

  def initialize(ctx)
    @ctx = ctx
    @audio_ready = !(ctx.nil? || ctx.typeof == "undefined")

    @bpm = 120
    @quantize = 2          # snap grid in steps: 1 (=1/32, "off"), 2 (1/16), 4 (1/8)
    @play_mode = :loop
    @metronome = false
    @is_playing = false
    @recording = false
    @current_loop_index = 0
    @selected_track = 0
    @song = []             # [{ loop: idx, repeats: n }]
    @pending = {}          # pointer_id => partial capture state
    @on_position = nil

    @loops = Array.new(MAX_LOOPS) { { bars: 1, notes: Array.new(MAX_TRACKS) { [] } } }

    @tracks = []
    if @audio_ready
      @seq_master = GainNode.new(@ctx, gain: 1.0)
      @seq_master.connect(@ctx[:destination])
      MAX_TRACKS.times do
        synth = Synthesizer.new(@ctx)
        synth.connect(@seq_master)
        @tracks << { synth: synth, muted: false, patch_json: nil }
      end
    else
      MAX_TRACKS.times { @tracks << { synth: nil, muted: false, patch_json: nil } }
    end

    load_state
  end

  def steps_per_bar
    BEATS_PER_BAR * STEPS_PER_BEAT
  end

  def loop_steps(loop_index = @current_loop_index)
    @loops[loop_index][:bars] * steps_per_bar
  end

  def loop_has_notes?(loop_index)
    @loops[loop_index][:notes].any? { |arr| !arr.empty? }
  end

  # --- Settings -------------------------------------------------------------

  def set_bpm(v)
    @bpm = v.to_i.clamp(30, 300)
    save_state
  end

  def set_quantize(steps)
    @quantize = steps.to_i.clamp(1, STEPS_PER_BEAT)
    save_state
  end

  def set_metronome(on)
    @metronome = !!on
    save_state
  end

  def set_play_mode(mode)
    @play_mode = (mode.to_sym == :song) ? :song : :loop
    save_state
  end

  def select_loop(index)
    @current_loop_index = index.to_i.clamp(0, MAX_LOOPS - 1)
    save_state
  end

  def select_track(index)
    @selected_track = index.to_i.clamp(0, MAX_TRACKS - 1)
    save_state
  end

  def set_loop_bars(loop_index, bars)
    @loops[loop_index][:bars] = bars.to_i.clamp(1, MAX_BARS)
    save_state
  end

  def clear_loop(loop_index)
    @loops[loop_index][:notes].each(&:clear)
    save_state
  end

  def set_track_mute(index, muted)
    @tracks[index][:muted] = !!muted
    save_state
  end

  def track_muted?(index)
    @tracks[index][:muted]
  end

  def track_synth(index)
    @tracks[index][:synth]
  end

  def track_has_patch?(index)
    !@tracks[index][:patch_json].nil?
  end

  # Import a purified-synth patch JSON into a track. Returns nil on success,
  # an error message string on failure.
  def import_track_patch(index, json_str)
    track = @tracks[index]
    return "audio unavailable" unless track[:synth]

    begin
      parsed = JSON.parse(json_str.to_s, symbolize_names: true)
      unless parsed.is_a?(Hash) && parsed[:nodes].is_a?(Array)
        return "invalid patch: missing nodes"
      end
      track[:synth].import_patch(json_str)
      track[:patch_json] = json_str.to_s
      save_state
      nil
    rescue => e
      "#{e.class}: #{e.message}"
    end
  end

  # --- Song list ------------------------------------------------------------

  def song_add_entry(loop_index, repeats)
    @song << { loop: loop_index.to_i.clamp(0, MAX_LOOPS - 1), repeats: repeats.to_i.clamp(1, 99) }
    save_state
  end

  def song_remove_entry(pos)
    @song.delete_at(pos)
    save_state
  end

  def song_move_entry(pos, delta)
    other = pos + delta
    return if other < 0 || other >= @song.length
    @song[pos], @song[other] = @song[other], @song[pos]
    save_state
  end

  # --- Note editing ---------------------------------------------------------

  def notes_for(track_index = @selected_track, loop_index = @current_loop_index)
    @loops[loop_index][:notes][track_index]
  end

  def add_note(track_index, loop_index, attrs = {})
    note = SeqNote.new(
      (attrs[:step] || 0).to_i.clamp(0, loop_steps(loop_index) - 1),
      [(attrs[:dur] || @quantize).to_i, 1].max,
      (attrs[:x] || 4).to_i.clamp(0, 8),
      (attrs[:y] || 4).to_i.clamp(0, 8),
      (attrs[:oct] || 0).to_i.clamp(-3, 3),
      (attrs[:dim] || 3).to_i,
      (attrs[:vel] || 0.8).to_f.clamp(0.01, 1.0)
    )
    list = @loops[loop_index][:notes][track_index]
    list << note
    sort_notes(list)
    save_state
    note
  end

  def delete_note(track_index, loop_index, note)
    @loops[loop_index][:notes][track_index].delete(note)
    save_state
  end

  # field: :step, :dur, :x, :y, :oct, :vel, :dim
  def update_note(track_index, loop_index, note, field, value)
    case field
    when :step then note.step = value.to_i.clamp(0, loop_steps(loop_index) - 1)
    when :dur  then note.dur = value.to_i.clamp(1, loop_steps(loop_index))
    when :x    then note.x = value.to_i.clamp(0, 8)
    when :y    then note.y = value.to_i.clamp(0, 8)
    when :oct  then note.oct = value.to_i.clamp(-3, 3)
    when :vel  then note.vel = value.to_f.clamp(0.01, 1.0)
    when :dim  then note.dim = [3, 4, 5].include?(value.to_i) ? value.to_i : 3
    end
    sort_notes(@loops[loop_index][:notes][track_index]) if field == :step
    save_state
  end

  def preview_note(track_index, note)
    return unless @audio_ready
    synth = @tracks[track_index][:synth]
    freq = note_freq(note)
    synth.schedule_note(freq, now + 0.02, note.dur * sec_per_step, velocity: note.vel)
  end

  # --- Playback -------------------------------------------------------------

  def playable?
    return false unless @audio_ready
    return @song.any? if @play_mode == :song
    true
  end

  def start
    return if @is_playing
    return unless playable?

    @ctx.call(:resume) if @ctx[:state].to_s == "suspended"

    @is_playing = true
    @play_loop = (@play_mode == :song) ? @song[0][:loop] : @current_loop_index
    @song_pos = 0
    @song_rep = 0
    @step = 0
    @next_note_time = now + 0.1

    JS.eval(<<~JAVASCRIPT)
      window.App.seqInterval = setInterval(() => {
        if (window.App && window.App.vm) {
          window.App.eval("$step_sequencer.scheduler", "SeqScheduler");
        }
      }, #{LOOKAHEAD_MS});
    JAVASCRIPT
  end

  def stop
    return unless @is_playing
    @is_playing = false
    JS.eval("clearInterval(window.App.seqInterval); delete window.App.seqInterval;")
    @pending.clear
    # Quiesce pooled voices / stop dynamic ones so nothing keeps ringing.
    @tracks.each { |t| t[:synth]&.stop_all_immediately }
  end

  def scheduler
    while @next_note_time < now + SCHEDULE_AHEAD_SEC
      schedule_step(@play_loop, @step, @next_note_time)
      notify_position if (@step % STEPS_PER_BEAT).zero?
      advance_step
    end
  end

  def position_label
    bar = @step / steps_per_bar + 1
    beat = (@step % steps_per_bar) / STEPS_PER_BEAT + 1
    if @play_mode == :song
      "S#{@song_pos + 1}/#{@song.length} L#{@play_loop + 1} #{bar}.#{beat}"
    else
      "L#{@play_loop + 1} #{bar}.#{beat}"
    end
  end

  # --- Realtime capture (called from PadGrid handlers) -----------------------

  def capture_note_on(pointer_id, x, y, velocity_127, octave_offset)
    return unless capturing?
    @pending[pointer_id] = {
      start: current_float_step,
      x: x.to_i, y: y.to_i, oct: octave_offset.to_i,
      dim: $audio_engine.dim,
      vel: (velocity_127.to_i.clamp(1, 127)) / 127.0
    }
  end

  def capture_note_off(pointer_id)
    p = @pending.delete(pointer_id)
    return unless p
    return unless capturing?

    total = loop_steps(@play_loop)
    snapped = ((p[:start] / @quantize).round * @quantize) % total
    # The playhead position wraps at the loop boundary, so the elapsed hold
    # can come out negative — unwrap it. Holds longer than one loop pass are
    # indistinguishable after the wrap and get capped at one loop.
    elapsed = (current_float_step - p[:start]) % total
    dur = [elapsed.round, 1].max
    dur = total if dur > total

    list = @loops[@play_loop][:notes][@selected_track]
    list << SeqNote.new(snapped, dur, p[:x], p[:y], p[:oct], p[:dim], p[:vel])
    sort_notes(list)
    save_state
  end

  def set_recording(on)
    @recording = !!on
    @pending.clear unless @recording
  end

  # --- Persistence (localStorage only) ---------------------------------------

  def save_state
    return unless @audio_ready
    JS.global[:localStorage].call(:setItem, STORAGE_KEY, serialize)
  rescue => e
    puts "[StepSequencer] save failed: #{e.message}"
  end

  def serialize
    JSON.generate({
      bpm: @bpm,
      quantize: @quantize,
      play_mode: @play_mode,
      metronome: @metronome,
      current_loop: @current_loop_index,
      selected_track: @selected_track,
      song: @song.map { |e| { l: e[:loop], r: e[:repeats] } },
      tracks: @tracks.map { |t| { muted: t[:muted], patch: t[:patch_json] } },
      loops: @loops.map { |l|
        { bars: l[:bars], notes: l[:notes].map { |arr| arr.map(&:to_h_compact) } }
      }
    })
  end

  def load_state
    return unless @audio_ready
    raw = JS.global[:localStorage].call(:getItem, STORAGE_KEY)
    return if raw.nil? || raw.typeof == "undefined"
    json = raw.to_s
    return if json.empty? || json == "null"

    data = JSON.parse(json, symbolize_names: true)

    @bpm = (data[:bpm] || 120).to_i.clamp(30, 300)
    @quantize = (data[:quantize] || 2).to_i.clamp(1, STEPS_PER_BEAT)
    @play_mode = data[:play_mode].to_s == "song" ? :song : :loop
    @metronome = !!data[:metronome]
    @current_loop_index = (data[:current_loop] || 0).to_i.clamp(0, MAX_LOOPS - 1)
    @selected_track = (data[:selected_track] || 0).to_i.clamp(0, MAX_TRACKS - 1)

    @song = (data[:song] || []).map do |e|
      { loop: e[:l].to_i.clamp(0, MAX_LOOPS - 1), repeats: e[:r].to_i.clamp(1, 99) }
    end

    (data[:tracks] || []).each_with_index do |t_data, i|
      break if i >= MAX_TRACKS
      @tracks[i][:muted] = !!t_data[:muted]
      if t_data[:patch] && @tracks[i][:synth]
        err = import_track_patch(i, t_data[:patch])
        puts "[StepSequencer] track #{i} patch restore failed: #{err}" if err
      end
    end

    (data[:loops] || []).each_with_index do |l_data, i|
      break if i >= MAX_LOOPS
      @loops[i][:bars] = (l_data[:bars] || 1).to_i.clamp(1, MAX_BARS)
      (l_data[:notes] || []).each_with_index do |arr, ti|
        break if ti >= MAX_TRACKS
        @loops[i][:notes][ti] = (arr || []).map { |h| SeqNote.from_h(h) }
        sort_notes(@loops[i][:notes][ti])
      end
    end
  rescue => e
    puts "[StepSequencer] load failed: #{e.message}"
  end

  private

  def now
    @ctx[:currentTime].to_f
  end

  def sec_per_step
    (60.0 / @bpm) / STEPS_PER_BEAT
  end

  def note_freq(note)
    $audio_engine.freq_for(note.x, note.y, note.oct, note.dim)
  end

  def sort_notes(list)
    list.sort_by! { |n| [n.step, n.x, n.y] }
  end

  def capturing?
    @is_playing && @recording && @play_mode == :loop
  end

  # Current playhead position in (fractional) steps within the playing loop,
  # derived from the scheduler cursor: @step is the next step to schedule at
  # @next_note_time, so "now" sits sec/step-scaled behind it.
  def current_float_step
    fs = @step - (@next_note_time - now) / sec_per_step
    total = loop_steps(@play_loop)
    ((fs % total) + total) % total
  end

  def schedule_step(loop_index, step, time)
    click(time, (step % steps_per_bar).zero?) if @metronome && (step % STEPS_PER_BEAT).zero?

    @loops[loop_index][:notes].each_with_index do |notes, track_index|
      track = @tracks[track_index]
      next if track[:muted] || track[:synth].nil?
      notes.each do |n|
        next unless n.step == step
        track[:synth].schedule_note(note_freq(n), time, n.dur * sec_per_step, velocity: n.vel)
      end
    end
  end

  def advance_step
    @next_note_time += sec_per_step
    @step += 1
    return if @step < loop_steps(@play_loop)

    @step = 0
    return unless @play_mode == :song

    @song_rep += 1
    entry = @song[@song_pos]
    if entry.nil? || @song_rep >= entry[:repeats]
      @song_rep = 0
      @song_pos = (@song_pos + 1) % @song.length
    end
    @play_loop = @song[@song_pos][:loop]
  end

  def notify_position
    @on_position&.call(position_label)
  rescue => e
    puts "[StepSequencer] position callback failed: #{e.message}"
  end

  def click(time, accent)
    osc = OscillatorNode.new(@ctx)
    osc.frequency.value = accent ? 1568.0 : 1046.5
    gain = GainNode.new(@ctx, gain: 0.0)
    osc.connect(gain)
    gain.connect(@seq_master)
    gain.gain.set_value_at_time(accent ? 0.5 : 0.3, time)
    gain.gain.exponential_ramp_to_value_at_time(0.001, time + 0.05)
    osc.start(time)
    osc.stop(time + 0.06)
  end
end
