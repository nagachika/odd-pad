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

    saved = JS.global[:localStorage].call(:getItem, STORAGE_KEY).to_s
    @enabled = (saved == "on")
    apply_visual
    $audio_engine.set_enabled(@enabled) if defined?($audio_engine) && $audio_engine

    @btn.call(:addEventListener, "click", proc {
      @enabled = !@enabled
      apply_visual
      JS.global[:localStorage].call(:setItem, STORAGE_KEY, @enabled ? "on" : "off")
      $audio_engine.set_enabled(@enabled) if defined?($audio_engine) && $audio_engine
    })

    element.call(:appendChild, label)
    element.call(:appendChild, @btn)
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

  AudioOutCtrl.register("audio-out-ctrl")
end
