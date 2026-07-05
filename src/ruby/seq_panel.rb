require 'js'
require 'web_component'
require 'step_sequencer'

# Sequencer panel: always-visible transport bar plus a collapsible editor
# area (Tracks / Loops / Song / Notes). All state lives in $step_sequencer;
# this component only renders it and forwards edits.
class SeqPanel
  include WebComponent

  QUANTIZE_OPTIONS = [["Off", 1], ["1/32", 1], ["1/16", 2], ["1/8", 4]]

  PANEL_CSS = <<~CSS
    :host {
      display: block;
      background: #202028;
      border-bottom: 1px solid #383838;
      font-size: 0.78rem;
      color: #ccc;
      user-select: none;
      -webkit-user-select: none;
    }
    * { box-sizing: border-box; }
    button, select, input {
      background: #333;
      color: #eee;
      border: 1px solid #555;
      border-radius: 4px;
      font-size: 0.78rem;
      padding: 2px 8px;
      cursor: pointer;
    }
    input[type="number"] { width: 56px; cursor: text; }
    textarea {
      width: 100%;
      height: 120px;
      background: #1a1a1a;
      color: #eee;
      border: 1px solid #555;
      border-radius: 4px;
      font-family: monospace;
      font-size: 0.7rem;
    }
    button.on  { background: #06c; border-color: #08f; }
    button.rec { color: #f66; }
    button.rec.on { background: #a11; border-color: #d33; color: #fff; }
    .transport {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 6px 14px;
      flex-wrap: wrap;
    }
    .transport .pos {
      font-family: monospace;
      color: #8fd;
      min-width: 9ch;
    }
    .transport label { color: #888; }
    .editor {
      border-top: 1px solid #333;
      padding: 6px 14px 10px;
      max-height: 38vh;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .editor[hidden] { display: none; }
    .section h3 {
      margin: 0 0 4px;
      font-size: 0.72rem;
      color: #789;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .track-row, .song-row {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 2px 0;
    }
    .track-row .name { width: 5ch; color: #aaa; }
    .track-row .patch-state { color: #7a7; font-size: 0.7rem; }
    .track-row.selected .name { color: #8cf; font-weight: 600; }
    .loops-grid {
      display: grid;
      grid-template-columns: repeat(8, 1fr);
      gap: 4px;
      max-width: 480px;
    }
    .loops-grid button.has-notes { border-color: #7a7; color: #ad8; }
    .loops-grid button.current { background: #06c; border-color: #08f; color: #fff; }
    table.notes {
      border-collapse: collapse;
      font-family: monospace;
      font-size: 0.72rem;
    }
    table.notes th, table.notes td {
      padding: 1px 6px;
      text-align: center;
      color: #bbb;
    }
    table.notes th { color: #789; }
    table.notes button { padding: 0 6px; }
    .modal-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,0.7);
      z-index: 50;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .modal {
      background: #26262e;
      border: 1px solid #555;
      border-radius: 8px;
      padding: 14px;
      width: min(90vw, 520px);
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .modal .error { color: #f77; font-size: 0.72rem; min-height: 1em; }
    .modal .row { display: flex; gap: 8px; justify-content: flex-end; }
  CSS

  def connected_callback(element)
    @element = element
    @shadow = element.call(:attachShadow, JS.eval("return { mode: 'open' }"))
    @seq = $step_sequencer
    @doc = JS.global[:document]

    style = @doc.call(:createElement, "style")
    style[:textContent] = PANEL_CSS
    @shadow.call(:appendChild, style)

    build_transport
    @editor = el("div", class: "editor")
    @editor[:hidden] = true
    @shadow.call(:appendChild, @editor)
    build_editor

    @seq.on_position = proc { |label| @pos[:textContent] = label }
  end

  private

  def el(tag, attrs = {}, text = nil)
    node = @doc.call(:createElement, tag)
    attrs.each do |k, v|
      case k
      when :class then node[:className] = v
      when :text  then node[:textContent] = v
      else node.call(:setAttribute, k.to_s, v.to_s)
      end
    end
    node[:textContent] = text if text
    node
  end

  def btn(label, attrs = {}, &handler)
    b = el("button", attrs, label)
    b.call(:addEventListener, "click", handler.to_proc)
    b
  end

  # --- Transport -------------------------------------------------------------

  def build_transport
    bar = el("div", class: "transport")

    @play_btn = btn("▶") { toggle_play }
    @rec_btn = btn("● REC", class: "rec") { toggle_rec }

    bar.call(:appendChild, @play_btn)
    bar.call(:appendChild, @rec_btn)

    bar.call(:appendChild, el("label", {}, "BPM"))
    @bpm_input = el("input", type: "number", min: "30", max: "300")
    @bpm_input[:value] = @seq.bpm.to_s
    @bpm_input.call(:addEventListener, "change", proc {
      @seq.set_bpm(@bpm_input[:value].to_i)
      @bpm_input[:value] = @seq.bpm.to_s
    })
    bar.call(:appendChild, @bpm_input)

    bar.call(:appendChild, el("label", {}, "Q"))
    @q_select = el("select")
    QUANTIZE_OPTIONS.each_with_index do |(label, _steps), i|
      opt = el("option", value: i.to_s)
      opt[:textContent] = label
      @q_select.call(:appendChild, opt)
    end
    @q_select[:value] = QUANTIZE_OPTIONS.index { |(_l, s)| s == @seq.quantize }.to_s
    @q_select.call(:addEventListener, "change", proc {
      @seq.set_quantize(QUANTIZE_OPTIONS[@q_select[:value].to_i][1])
    })
    bar.call(:appendChild, @q_select)

    @metro_btn = btn("Metro") {
      @seq.set_metronome(!@seq.metronome)
      set_toggle(@metro_btn, @seq.metronome)
    }
    set_toggle(@metro_btn, @seq.metronome)
    bar.call(:appendChild, @metro_btn)

    @mode_btn = btn(mode_label) {
      @seq.set_play_mode(@seq.play_mode == :loop ? :song : :loop)
      @mode_btn[:textContent] = mode_label
      sync_rec_availability
    }
    bar.call(:appendChild, @mode_btn)

    @pos = el("span", class: "pos")
    @pos[:textContent] = "—"
    bar.call(:appendChild, @pos)

    # Track open/closed in Ruby: reading the JS `hidden` property back gives
    # a JS::Object, which is truthy in Ruby even when it wraps `false`.
    @editor_open = false
    @expand_btn = btn("▼ Edit") {
      @editor_open = !@editor_open
      @editor[:hidden] = !@editor_open
      @expand_btn[:textContent] = @editor_open ? "▲ Close" : "▼ Edit"
      render_editor if @editor_open
    }
    bar.call(:appendChild, @expand_btn)

    @shadow.call(:appendChild, bar)
  end

  def mode_label
    @seq.play_mode == :song ? "Mode: Song" : "Mode: Loop"
  end

  def toggle_play
    if @seq.is_playing
      @seq.stop
      @play_btn[:textContent] = "▶"
      @pos[:textContent] = "—"
    else
      return unless @seq.playable?
      @seq.start
      @play_btn[:textContent] = "■"
    end
  end

  def toggle_rec
    @seq.set_recording(!@seq.recording)
    set_toggle(@rec_btn, @seq.recording)
    sync_monitor
  end

  def sync_rec_availability
    if @seq.play_mode == :song && @seq.recording
      @seq.set_recording(false)
      set_toggle(@rec_btn, false)
      sync_monitor
    end
    @rec_btn[:disabled] = @seq.play_mode == :song
  end

  # While armed, pads monitor through the selected track's synth.
  def sync_monitor
    $audio_engine.monitor_synth =
      @seq.recording ? @seq.track_synth(@seq.selected_track) : nil
  end

  def set_toggle(button, on)
    if on
      button[:classList].call(:add, "on")
    else
      button[:classList].call(:remove, "on")
    end
  end

  # --- Editor ----------------------------------------------------------------

  def build_editor
    @tracks_sec = section("Tracks")
    @loops_sec = section("Loops")
    @song_sec = section("Song")
    @notes_sec = section("Notes")
    render_editor
  end

  def section(title)
    sec = el("div", class: "section")
    sec.call(:appendChild, el("h3", {}, title))
    body = el("div")
    sec.call(:appendChild, body)
    @editor.call(:appendChild, sec)
    body
  end

  def render_editor
    render_tracks
    render_loops
    render_song
    render_notes
  end

  def clear(node)
    node[:textContent] = ""
  end

  def render_tracks
    clear(@tracks_sec)
    StepSequencer::MAX_TRACKS.times do |i|
      row = el("div", class: i == @seq.selected_track ? "track-row selected" : "track-row")
      row.call(:appendChild, btn("T#{i + 1}", class: "name") {
        @seq.select_track(i)
        sync_monitor if @seq.recording
        render_tracks
        render_notes
      })

      mute = btn("M") {
        @seq.set_track_mute(i, !@seq.track_muted?(i))
        set_toggle(mute, @seq.track_muted?(i))
      }
      set_toggle(mute, @seq.track_muted?(i))
      row.call(:appendChild, mute)

      row.call(:appendChild, btn("Patch…") { open_patch_modal(i) })
      row.call(:appendChild,
               el("span", { class: "patch-state" },
                  @seq.track_has_patch?(i) ? "imported" : "default"))
      @tracks_sec.call(:appendChild, row)
    end
  end

  def render_loops
    clear(@loops_sec)
    grid = el("div", class: "loops-grid")
    StepSequencer::MAX_LOOPS.times do |i|
      cls = "loop-btn"
      cls += " has-notes" if @seq.loop_has_notes?(i)
      cls += " current" if i == @seq.current_loop_index
      grid.call(:appendChild, btn("#{i + 1}", class: cls) {
        @seq.select_loop(i)
        render_loops
        render_notes
      })
    end
    @loops_sec.call(:appendChild, grid)

    ctl = el("div", class: "track-row")
    ctl.call(:appendChild, el("label", {}, "Bars"))
    bars = el("select")
    (1..StepSequencer::MAX_BARS).each do |b|
      opt = el("option", value: b.to_s)
      opt[:textContent] = b.to_s
      bars.call(:appendChild, opt)
    end
    bars[:value] = @seq.loops[@seq.current_loop_index][:bars].to_s
    bars.call(:addEventListener, "change", proc {
      @seq.set_loop_bars(@seq.current_loop_index, bars[:value].to_i)
      render_notes
    })
    ctl.call(:appendChild, bars)
    ctl.call(:appendChild, btn("Clear loop") {
      @seq.clear_loop(@seq.current_loop_index)
      render_loops
      render_notes
    })
    @loops_sec.call(:appendChild, ctl)
  end

  def render_song
    clear(@song_sec)
    @seq.song.each_with_index do |entry, pos|
      row = el("div", class: "song-row")
      row.call(:appendChild, el("span", {}, "#{pos + 1}. L#{entry[:loop] + 1} ×#{entry[:repeats]}"))
      row.call(:appendChild, btn("↑") { @seq.song_move_entry(pos, -1); render_song })
      row.call(:appendChild, btn("↓") { @seq.song_move_entry(pos, 1); render_song })
      row.call(:appendChild, btn("✕") { @seq.song_remove_entry(pos); render_song })
      @song_sec.call(:appendChild, row)
    end

    add_row = el("div", class: "song-row")
    loop_sel = el("select")
    StepSequencer::MAX_LOOPS.times do |i|
      opt = el("option", value: i.to_s)
      opt[:textContent] = "L#{i + 1}"
      loop_sel.call(:appendChild, opt)
    end
    rep = el("input", type: "number", min: "1", max: "99")
    rep[:value] = "1"
    add_row.call(:appendChild, loop_sel)
    add_row.call(:appendChild, el("label", {}, "×"))
    add_row.call(:appendChild, rep)
    add_row.call(:appendChild, btn("Add") {
      @seq.song_add_entry(loop_sel[:value].to_i, rep[:value].to_i)
      render_song
    })
    @song_sec.call(:appendChild, add_row)
  end

  NOTE_FIELDS = [
    [:step, 1], [:dur, 1], [:x, 1], [:y, 1], [:oct, 1], [:dim, 1]
  ]

  def render_notes
    clear(@notes_sec)
    track = @seq.selected_track
    loop_i = @seq.current_loop_index
    notes = @seq.notes_for(track, loop_i)

    head = el("div", { class: "track-row" },
              "T#{track + 1} / L#{loop_i + 1} — #{notes.length} notes")
    head.call(:appendChild, btn("+ Note") {
      @seq.add_note(track, loop_i, dim: $audio_engine.dim)
      render_notes
      render_loops
    })
    @notes_sec.call(:appendChild, head)
    return if notes.empty?

    table = el("table", class: "notes")
    thead = el("tr")
    ["step", "dur", "X", "Y", "oct", "dim", "vel", "", ""].each do |h|
      thead.call(:appendChild, el("th", {}, h))
    end
    table.call(:appendChild, thead)

    notes.each do |note|
      table.call(:appendChild, note_row(track, loop_i, note))
    end
    @notes_sec.call(:appendChild, table)
  end

  def note_row(track, loop_i, note)
    tr = el("tr")
    NOTE_FIELDS.each do |field, delta|
      td = el("td")
      td.call(:appendChild, btn("−") {
        step_field(track, loop_i, note, field, -delta)
      })
      td.call(:appendChild, el("span", {}, " #{note[field]} "))
      td.call(:appendChild, btn("+") {
        step_field(track, loop_i, note, field, delta)
      })
      tr.call(:appendChild, td)
    end

    vel_td = el("td")
    vel_td.call(:appendChild, btn("−") { step_vel(track, loop_i, note, -0.1) })
    vel_td.call(:appendChild, el("span", {}, " #{(note.vel * 127).round} "))
    vel_td.call(:appendChild, btn("+") { step_vel(track, loop_i, note, 0.1) })
    tr.call(:appendChild, vel_td)

    play_td = el("td")
    play_td.call(:appendChild, btn("♪") { @seq.preview_note(track, note) })
    tr.call(:appendChild, play_td)

    del_td = el("td")
    del_td.call(:appendChild, btn("✕") {
      @seq.delete_note(track, loop_i, note)
      render_notes
      render_loops
    })
    tr.call(:appendChild, del_td)
    tr
  end

  def step_field(track, loop_i, note, field, delta)
    if field == :dim
      order = [3, 4, 5]
      idx = (order.index(note.dim) || 0) + (delta.positive? ? 1 : -1)
      @seq.update_note(track, loop_i, note, :dim, order[idx % 3])
    else
      @seq.update_note(track, loop_i, note, field, note[field] + delta)
    end
    render_notes
  end

  def step_vel(track, loop_i, note, delta)
    @seq.update_note(track, loop_i, note, :vel, note.vel + delta)
    render_notes
  end

  # --- Patch import modal ------------------------------------------------------

  def open_patch_modal(track_index)
    backdrop = el("div", class: "modal-backdrop")
    modal = el("div", class: "modal")
    modal.call(:appendChild,
               el("div", {}, "Track #{track_index + 1} patch JSON (purified-synth format)"))
    ta = el("textarea", placeholder: '{"nodes": [...], "connections": [...]}')
    error = el("div", class: "error")
    row = el("div", class: "row")

    row.call(:appendChild, btn("Cancel") { backdrop.call(:remove) })
    row.call(:appendChild, btn("Import") {
      err = @seq.import_track_patch(track_index, ta[:value].to_s)
      if err
        error[:textContent] = err
      else
        backdrop.call(:remove)
        render_tracks
      end
    })

    modal.call(:appendChild, ta)
    modal.call(:appendChild, error)
    modal.call(:appendChild, row)
    backdrop.call(:appendChild, modal)
    @shadow.call(:appendChild, backdrop)
  end

  SeqPanel.register("seq-panel")
end
