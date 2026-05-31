require 'js'
require 'json'
require 'synthesizer'

class AudioEngine
  ROOT_FREQ = 261.63   # C4
  CENTER_X  = 4
  CENTER_Y  = 4

  attr_reader :enabled, :dim

  def initialize(ctx)
    @ctx = ctx
    @enabled = false
    @dim = 3
    @voices = {}  # pointer_id => { voice:, freq:, octave: }
    @freq_track_ids = []

    if ctx.nil? || ctx.typeof == "undefined"
      puts "[AudioEngine] No AudioContext available; local audio disabled."
      @synth = nil
      return
    end

    @synth = Synthesizer.new(ctx)
    patch_json = JS.global[:App].call(:loadDefaultPatch).to_s
    unless patch_json.empty?
      begin
        @synth.import_patch(patch_json)
      rescue => e
        puts "[AudioEngine] Failed to import default patch: #{e.message}"
      end
    end

    @freq_track_ids = collect_freq_track_ids
  end

  def set_enabled(on)
    return if on == @enabled
    return unless @synth
    @enabled = on ? true : false
    if @enabled
      @ctx.call(:resume) if @ctx[:state].to_s == "suspended"
      @synth.connect(@ctx[:destination])
    else
      stop_all_held
      begin
        @synth.disconnect
      rescue => e
        puts "[AudioEngine] disconnect warning: #{e.message}"
      end
    end
  end

  def set_dim(d)
    @dim = d.to_i
  end

  def set_volume(v_0_127)
    return unless @synth
    @synth.volume = v_0_127.to_i / 127.0
  end

  def freq_for(x, y, octave_offset, dim)
    b = x.to_i - CENTER_X
    yc = y.to_i - CENTER_Y
    c = (dim == 3) ? yc : 0
    d = (dim == 4) ? yc : 0
    e = (dim == 5) ? yc : 0
    f = ROOT_FREQ
    f *= 2.0 ** octave_offset.to_i
    f *= 1.5 ** b
    f *= 1.25 ** c
    f *= 1.75 ** d
    f *= 2.75 ** e
    f
  end

  def note_on(pointer_id, x, y, velocity_127, octave_offset)
    return unless @enabled && @synth
    freq = freq_for(x, y, octave_offset, @dim)
    v = (velocity_127.to_i.clamp(1, 127)) / 127.0
    @synth.note_on(freq, velocity: v)
    voice = @synth.voice_for(freq)
    @voices[pointer_id] = { voice: voice, freq: freq, octave: octave_offset.to_i }
  end

  def note_off(pointer_id)
    state = @voices.delete(pointer_id)
    return unless state && @synth
    @synth.note_off(state[:freq])
  end

  def set_octave_offset(pointer_id, offset)
    state = @voices[pointer_id]
    return unless state
    new_offset = offset.to_i
    return if new_offset == state[:octave]
    state[:octave] = new_offset
    cents = new_offset * 1200
    voice = state[:voice]
    return unless voice
    voice.nodes.each do |id, node|
      next unless @freq_track_ids.include?(id.to_s)
      next unless node.is_a?(OscillatorNode)
      node.detune.value = cents
    end
  end

  private

  def collect_freq_track_ids
    patch = @synth.custom_patch
    return [] unless patch && patch[:nodes]
    patch[:nodes].select { |n| n[:freq_track] }.map { |n| n[:id].to_s }
  end

  def stop_all_held
    @voices.each_value do |s|
      begin
        s[:voice]&.stop_immediately
      rescue => e
        puts "[AudioEngine] stop_immediately warning: #{e.message}"
      end
    end
    @voices.clear
    @synth.stop_all_immediately if @synth.respond_to?(:stop_all_immediately)
  end
end
