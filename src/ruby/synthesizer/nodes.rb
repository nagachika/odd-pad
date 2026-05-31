require_relative "audio_node_wrapper"

class OscillatorNode < AudioNodeWrapper
  def initialize(ctx, type: "sine", frequency: 440.0)
    native = ctx.call(:createOscillator)
    super(ctx, native)
    self.type = type
    self.frequency.value = frequency
  end

  def type=(val)
    @native_node[:type] = val.to_s
  end

  def frequency
    @frequency ||= param(:frequency)
  end

  def detune
    @detune ||= param(:detune)
  end

  def start(time = 0)
    @native_node.call(:start, time.to_f)
  end

  def stop(time = 0)
    @native_node.call(:stop, time.to_f)
  end
end

class GainNode < AudioNodeWrapper
  def initialize(ctx, gain: 1.0)
    native = ctx.call(:createGain)
    super(ctx, native)
    self.gain.value = gain
  end

  def gain
    @gain ||= param(:gain)
  end
end

class BiquadFilterNode < AudioNodeWrapper
  def initialize(ctx, type: "lowpass", frequency: 350.0, q: 1.0)
    native = ctx.call(:createBiquadFilter)
    super(ctx, native)
    self.type = type
    self.frequency.value = frequency
    self.Q.value = q
  end

  def type=(val)
    @native_node[:type] = val.to_s
  end

  def frequency
    @frequency ||= param(:frequency)
  end

  def detune
    @detune ||= param(:detune)
  end

  def Q
    @Q ||= param(:Q)
  end

  def gain
    # Only used for peaking/shelf filters
    @gain ||= param(:gain)
  end
end

class DelayNode < AudioNodeWrapper
  def initialize(ctx, delay_time: 0.0)
    native = ctx.call(:createDelay, 5.0) # Max delay time 5s
    super(ctx, native)
    self.delay_time.value = delay_time
  end

  def delay_time
    @delay_time ||= param(:delayTime)
  end
end

class ConvolverNode < AudioNodeWrapper
  def initialize(ctx)
    native = ctx.call(:createConvolver)
    super(ctx, native)
  end

  def buffer=(buffer)
    @native_node[:buffer] = buffer
  end

  def normalize=(val)
    @native_node[:normalize] = val
  end
end

class DynamicsCompressorNode < AudioNodeWrapper
  def initialize(ctx)
    native = ctx.call(:createDynamicsCompressor)
    super(ctx, native)
  end

  def threshold
    @threshold ||= param(:threshold)
  end

  def knee
    @knee ||= param(:knee)
  end

  def ratio
    @ratio ||= param(:ratio)
  end

  def attack
    @attack ||= param(:attack)
  end

  def release
    @release ||= param(:release)
  end
end

class CombFilterNode < AudioNodeWrapper
  def initialize(ctx, frequency: 440.0, q: 0.0)
    @input_gain = ctx.call(:createGain)
    @output_gain = ctx.call(:createGain)
    @delay = ctx.call(:createDelay, 1.0) # Max delay 1s
    @feedback = ctx.call(:createGain)

    super(ctx, @input_gain)

    # Topology:
    # Input -> Output (Dry)
    # Input -> Delay -> Output (Wet)
    # Delay -> Feedback -> Delay (Feedback Loop)

    @input_gain.connect(@output_gain)
    @input_gain.connect(@delay)
    @delay.connect(@output_gain)
    @delay.connect(@feedback)
    @feedback.connect(@delay)

    self.set_frequency(frequency)
    self.set_q(q)
  end

  def connect(destination, output_index = 0, input_index = 0)
    dest_node = destination.is_a?(AudioNodeWrapper) ? destination.native_node : destination
    @output_gain.call(:connect, dest_node, output_index, input_index)
    self
  end

  def set_frequency(hz)
    h = hz.to_f
    h = 20.0 if h < 20.0
    # f = 1/T => T = 1/f
    @delay[:delayTime][:value] = 1.0 / h
  end

  def set_q(val)
    # Map Q (0..10+) to Feedback (0..0.95)
    f = val.to_f * 0.1
    f = 0.95 if f > 0.95
    f = 0.0 if f < 0.0
    @feedback[:gain][:value] = f
  end

  def param(name)
    case name.to_s
    when "frequency"
      # Note: This returns the raw delayTime AudioParam (in seconds), not frequency in Hz.
      # Modulation sources connected here will control delay time directly.
      # set_frequency() handles the Hz-to-seconds conversion for static values.
      AudioParamWrapper.new(@delay[:delayTime])
    when "q", "Q", "resonance"
      AudioParamWrapper.new(@feedback[:gain])
    else
      super(name)
    end
  end
end

class NoiseNode < AudioNodeWrapper
  def initialize(ctx, buffer)
    native = ctx.call(:createBufferSource)
    super(ctx, native)
    @native_node[:buffer] = buffer
    @native_node[:loop] = true
  end

  def start(time = 0)
    @native_node.call(:start, time.to_f)
  end

  def stop(time = 0)
    @native_node.call(:stop, time.to_f)
  end
end

class ConstantSourceNode < AudioNodeWrapper
  def initialize(ctx, offset: 1.0)
    native = ctx.call(:createConstantSource)
    super(ctx, native)
    self.offset.value = offset
  end

  def offset
    @offset ||= param(:offset)
  end

  def start(time = 0)
    @native_node.call(:start, time.to_f)
  end

  def stop(time = 0)
    @native_node.call(:stop, time.to_f)
  end
end

class AnalyserNode < AudioNodeWrapper
  def initialize(ctx)
    native = ctx.call(:createAnalyser)
    super(ctx, native)
  end

  def fft_size=(size)
    @native_node[:fftSize] = size
  end
end
