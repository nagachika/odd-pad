require 'js'
require 'web_component'

class DimCtrl
  include WebComponent

  CC_DIM = 20

  def connected_callback(element)
    doc = JS.global[:document]
    element[:className] = "ctrl-group"

    label = doc.call(:createElement, "label")
    label[:textContent] = "Dim"

    @btn_group = doc.call(:createElement, "span")
    @btn_group[:className] = "dim-btn-group"

    @buttons = {}
    [3, 4, 5].each do |v|
      btn = doc.call(:createElement, "button")
      btn[:textContent] = v.to_s
      btn[:className] = "dim-btn"
      btn[:classList].call(:add, "active") if v == 3
      btn[:dataset][:dim] = v.to_s
      btn.call(:addEventListener, "click", proc { |e|
        set_active(v)
        $midi_sender.send_cc(CC_DIM, v)
        $audio_engine.set_dim(v) if defined?($audio_engine) && $audio_engine
      })
      @btn_group.call(:appendChild, btn)
      @buttons[v] = btn
    end

    element.call(:appendChild, label)
    element.call(:appendChild, @btn_group)

    JS.global[:document].call(:addEventListener, "mirror-mode-change", method(:on_mirror_mode_change).to_proc)
    JS.global[:document].call(:addEventListener, "mirror-cc",           method(:on_mirror_cc).to_proc)
  end

  private

  def set_active(v)
    @buttons.each do |val, btn|
      if val == v
        btn[:classList].call(:add, "active")
      else
        btn[:classList].call(:remove, "active")
      end
    end
  end

  def on_mirror_mode_change(event)
    active = event[:detail][:active].to_s == "true"
    @buttons.each_value { |btn| btn[:disabled] = active }
  end

  def on_mirror_cc(event)
    return unless event[:detail][:cc].to_i == CC_DIM
    v = event[:detail][:value].to_i
    return unless @buttons.key?(v)
    set_active(v)
  end

  DimCtrl.register("dim-ctrl")
end

class VolCtrl
  include WebComponent

  CC_VOLUME = 7

  def connected_callback(element)
    doc = JS.global[:document]
    element[:className] = "ctrl-group"

    label = doc.call(:createElement, "label")
    label[:htmlFor] = "ctrl-volume"
    label[:textContent] = "Vol"

    @input = doc.call(:createElement, "input")
    @input[:type] = "range"
    @input[:id] = "ctrl-volume"
    @input[:min] = "0"
    @input[:max] = "127"
    @input[:value] = "100"
    @input[:step] = "1"
    @input.call(:addEventListener, "input", proc { |e|
      v = e[:target][:value].to_i
      $midi_sender.send_cc(CC_VOLUME, v)
      $audio_engine.set_volume(v) if defined?($audio_engine) && $audio_engine
    })

    element.call(:appendChild, label)
    element.call(:appendChild, @input)

    # Sync initial slider value to audio engine
    $audio_engine.set_volume(@input[:value].to_i) if defined?($audio_engine) && $audio_engine

    JS.global[:document].call(:addEventListener, "mirror-mode-change", method(:on_mirror_mode_change).to_proc)
    JS.global[:document].call(:addEventListener, "mirror-cc",           method(:on_mirror_cc).to_proc)
  end

  private

  def on_mirror_mode_change(event)
    @input[:disabled] = event[:detail][:active].to_s == "true"
  end

  def on_mirror_cc(event)
    return unless event[:detail][:cc].to_i == CC_VOLUME
    @input[:value] = event[:detail][:value].to_i.to_s
  end

  VolCtrl.register("vol-ctrl")
end
