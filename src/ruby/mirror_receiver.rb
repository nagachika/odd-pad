require 'js'

# Listen to a Web MIDI input and dispatch DOM CustomEvents so the rest of the
# UI can mirror a tablet running odd-pad. The receiver itself owns no DOM —
# components subscribe to:
#
#   mirror-mode-change  detail: { active, input_id, input_name, connected }
#   mirror-note-on      detail: { note, velocity }
#   mirror-note-off     detail: { note }
#   mirror-cc           detail: { cc, value }   # cc ∈ {20, 7} only
class MirrorReceiver
  NOTE_ON     = 0x90
  NOTE_OFF    = 0x80
  CC          = 0xB0
  STATUS_MASK = 0xF0

  CC_DIM     = 20
  CC_VOLUME  = 7
  CC_ALLOWED = [CC_DIM, CC_VOLUME].freeze

  JS_NULL = JS.eval("return null")

  attr_reader :active, :input_id

  def initialize
    @active   = false
    @input_id = nil
    @input    = nil
    @on_midi_message = method(:on_midi_message).to_proc

    access = midi_access
    return unless access
    access[:onstatechange] = method(:on_state_change).to_proc
  end

  def midi_supported?
    !midi_access.nil?
  end

  # Returns Array of [id, name] for currently available MIDI inputs.
  def available_inputs
    access = midi_access
    return [] unless access
    list = []
    access[:inputs].call(:forEach, proc { |input, *|
      list << [input[:id].to_s, input[:name].to_s]
    })
    list
  end

  def connected?
    return false unless @input
    @input[:state].to_s == "connected"
  end

  def activate(input_id)
    access = midi_access
    return false unless access
    input = access[:inputs].call(:get, input_id)
    return false if input.typeof.to_s == "undefined" || input.nil?

    detach_input
    @input    = input
    @input_id = input_id.to_s
    @input[:onmidimessage] = @on_midi_message
    @active   = true
    fire_mode_change
    true
  end

  def deactivate
    return unless @active
    detach_input
    @active   = false
    @input_id = nil
    fire_mode_change
  end

  private

  def midi_access
    return nil unless JS.global[:App].call(:hasMidiAccess).to_s == "true"
    JS.global[:App][:midiAccess]
  end

  def detach_input
    return unless @input
    @input[:onmidimessage] = JS_NULL
    @input = nil
  end

  def fire_mode_change
    dispatch("mirror-mode-change",
      "active"     => @active,
      "input_id"   => @input_id,
      "input_name" => @input ? @input[:name].to_s : nil,
      "connected"  => @active ? connected? : false,
    )
  end

  def on_state_change(_event)
    return unless @active && @input_id
    # Re-emit mode change so listeners (badge, dialog hint) can refresh.
    fire_mode_change
  end

  def on_midi_message(event)
    data = event[:data]
    return if data.typeof.to_s == "undefined"
    len = data[:length].to_i
    return if len < 1
    status = data[0].to_i

    case status & STATUS_MASK
    when NOTE_ON
      return if len < 3
      note     = data[1].to_i
      velocity = data[2].to_i
      if velocity == 0
        dispatch("mirror-note-off", "note" => note)
      else
        dispatch("mirror-note-on", "note" => note, "velocity" => velocity)
      end
    when NOTE_OFF
      return if len < 2
      note = data[1].to_i
      dispatch("mirror-note-off", "note" => note)
    when CC
      return if len < 3
      cc    = data[1].to_i
      value = data[2].to_i
      return unless CC_ALLOWED.include?(cc)
      dispatch("mirror-cc", "cc" => cc, "value" => value)
    end
  end

  def dispatch(name, detail_hash)
    detail = JS.eval("return {}")
    detail_hash.each do |k, v|
      detail[k.to_s.to_sym] = v.nil? ? JS_NULL : v
    end
    JS.global[:App].call(:dispatchEvent, name, detail)
  end
end
