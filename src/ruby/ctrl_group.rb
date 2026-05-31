require 'js'
require 'web_component'

class DimCtrl
  include WebComponent

  def connected_callback(element)
    doc = JS.global[:document]
    element[:className] = "ctrl-group"

    label = doc.call(:createElement, "label")
    label[:textContent] = "Dim"

    btn_group = doc.call(:createElement, "span")
    btn_group[:className] = "dim-btn-group"

    [3, 4, 5].each do |v|
      btn = doc.call(:createElement, "button")
      btn[:textContent] = v.to_s
      btn[:className] = "dim-btn"
      btn[:classList].call(:add, "active") if v == 3
      btn[:dataset][:dim] = v.to_s
      btn.call(:addEventListener, "click", proc { |e|
        btn_group.call(:querySelectorAll, ".dim-btn").call(:forEach, proc { |b|
          b[:classList].call(:remove, "active")
        })
        e[:currentTarget][:classList].call(:add, "active")
        $midi_sender.send_cc(20, v)
        $audio_engine.set_dim(v) if defined?($audio_engine) && $audio_engine
      })
      btn_group.call(:appendChild, btn)
    end

    element.call(:appendChild, label)
    element.call(:appendChild, btn_group)
  end

  DimCtrl.register("dim-ctrl")
end

class VolCtrl
  include WebComponent

  def connected_callback(element)
    doc = JS.global[:document]
    element[:className] = "ctrl-group"

    label = doc.call(:createElement, "label")
    label[:htmlFor] = "ctrl-volume"
    label[:textContent] = "Vol"

    input = doc.call(:createElement, "input")
    input[:type] = "range"
    input[:id] = "ctrl-volume"
    input[:min] = "0"
    input[:max] = "127"
    input[:value] = "100"
    input[:step] = "1"
    input.call(:addEventListener, "input", proc { |e|
      v = e[:target][:value].to_i
      $midi_sender.send_cc(7, v)
      $audio_engine.set_volume(v) if defined?($audio_engine) && $audio_engine
    })

    element.call(:appendChild, label)
    element.call(:appendChild, input)

    # Sync initial slider value to audio engine
    $audio_engine.set_volume(input[:value].to_i) if defined?($audio_engine) && $audio_engine
  end

  VolCtrl.register("vol-ctrl")
end
