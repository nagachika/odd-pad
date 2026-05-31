require 'js'
require 'web_component'

class AudioOutCtrl
  include WebComponent
  STORAGE_KEY = "odd-pad.audio-out"

  def connected_callback(element)
    doc = JS.global[:document]
    element[:className] = "ctrl-group"
    element[:id] = "audio-out-group"

    label = doc.call(:createElement, "label")
    label[:textContent] = "Audio"

    @btn = doc.call(:createElement, "button")
    @btn[:className] = "dim-btn"

    @mirror_active   = false
    @saved_enabled   = nil

    saved = JS.global[:localStorage].call(:getItem, STORAGE_KEY).to_s
    @enabled = (saved == "on")
    apply_visual
    $audio_engine.set_enabled(@enabled) if defined?($audio_engine) && $audio_engine

    @btn.call(:addEventListener, "click", proc {
      next if @mirror_active
      @enabled = !@enabled
      apply_visual
      JS.global[:localStorage].call(:setItem, STORAGE_KEY, @enabled ? "on" : "off")
      $audio_engine.set_enabled(@enabled) if defined?($audio_engine) && $audio_engine
    })

    element.call(:appendChild, label)
    element.call(:appendChild, @btn)

    JS.global[:document].call(:addEventListener, "mirror-mode-change", method(:on_mirror_mode_change).to_proc)
  end

  private

  def apply_visual
    @btn[:textContent] = @enabled ? "ON" : "OFF"
    if @enabled
      @btn[:classList].call(:add, "active")
    else
      @btn[:classList].call(:remove, "active")
    end
  end

  def on_mirror_mode_change(event)
    active = event[:detail][:active].to_s == "true"
    if active && !@mirror_active
      @saved_enabled = @enabled
      if @enabled
        @enabled = false
        apply_visual
        $audio_engine.set_enabled(false) if defined?($audio_engine) && $audio_engine
      end
      @btn[:disabled] = true
    elsif !active && @mirror_active
      @btn[:disabled] = false
      if !@saved_enabled.nil? && @saved_enabled != @enabled
        @enabled = @saved_enabled
        apply_visual
        $audio_engine.set_enabled(@enabled) if defined?($audio_engine) && $audio_engine
      end
      @saved_enabled = nil
    end
    @mirror_active = active
  end

  AudioOutCtrl.register("audio-out-ctrl")
end
