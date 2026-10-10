extends Node
## Procedural sound: one generator stream mixed in GDScript, no audio
## files. Engine note that climbs through gears, wind that rises with
## speed, footsteps on foot, birds by day and crickets at night, tyre skid
## on the handbrake, and a two-tone horn.

const RATE := 16000.0

var state := {"driving": false, "speed": 0.0, "throttle": 0.0, "handbrake": false,
	"foot_speed": 0.0, "grounded": true, "night": false, "horn": false}

var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _rng := RandomNumberGenerator.new()

# Oscillator / filter state.
var _eng_phase := 0.0
var _eng_rpm := 0.3        # smoothed 0..1
var _eng_amp := 0.0
var _wind_lp := 0.0
var _wind_lp2 := 0.0
var _wind_amp := 0.0
var _step_timer := 0.0
var _step_env := 0.0
var _step_lp := 0.0
var _bird_timer := 2.0
var _bird_notes: Array = []  # [freq, remaining samples, sweep]
var _bird_phase := 0.0
var _cricket_phase := 0.0
var _cricket_gate := 0.0
var _skid_env := 0.0
var _skid_lp := 0.0
var _horn_phase1 := 0.0
var _horn_phase2 := 0.0
var _horn_env := 0.0
var _ai_horns: Array = []  # [remaining samples, gain, phase1, phase2]


func _ready() -> void:
	_rng.seed = 11
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.12
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	_player.volume_db = -6.0
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback()


func _process(_delta: float) -> void:
	if _playback == null:
		return
	var n := _playback.get_frames_available()
	if n > 0:
		_playback.push_buffer(render(n))


## A short horn from another car `distance` metres away.
func ai_honk(distance: float) -> void:
	var gain := clampf(1.0 - distance / 80.0, 0.0, 1.0) * 0.35
	if gain > 0.01:
		_ai_horns.append([int(RATE * _rng.randf_range(0.35, 0.7)), gain, 0.0, 0.0, _rng.randf_range(330.0, 380.0)])


## `n` frames of mixed audio for the current state; advances all voices.
func render(n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(n)
	var dt := 1.0 / RATE
	var speed: float = state["speed"]
	var kmh := speed * 3.6
	# Engine: which gear, and where in its band.
	var gears := [0.0, 22.0, 48.0, 80.0, 125.0]
	var rpm_target := 0.18
	if state["driving"]:
		rpm_target = 0.25 + 0.35 * state["throttle"] * 0.4
		for g in 4:
			if kmh >= gears[g] and kmh < gears[g + 1]:
				rpm_target = 0.3 + 0.6 * (kmh - gears[g]) / (gears[g + 1] - gears[g])
				break
		if kmh >= gears[4]:
			rpm_target = 0.95
		rpm_target += 0.1 * state["throttle"]
	var amp_target: float = (0.12 + 0.18 * state["throttle"]) if state["driving"] else 0.0
	var wind_target: float = 0.03 + clampf(speed / 40.0, 0.0, 1.0) * 0.35
	var foot_speed: float = state["foot_speed"] if not state["driving"] else 0.0
	var step_period := 0.0
	if foot_speed > 0.3 and state["grounded"]:
		step_period = clampf(0.95 / foot_speed, 0.28, 0.9)
	var night: bool = state["night"]
	var skid_target := 0.0
	if state["driving"] and state["handbrake"] and speed > 4.0:
		skid_target = clampf(speed / 15.0, 0.3, 1.0)
	var horn_target := 0.9 if state["horn"] else 0.0
	var smooth := 1.0 - exp(-dt * 6.0)
	var fast := 1.0 - exp(-dt * 40.0)

	for i in n:
		# --- engine ---
		_eng_rpm += (rpm_target - _eng_rpm) * smooth
		_eng_amp += (amp_target - _eng_amp) * smooth
		var f0 := 28.0 + _eng_rpm * 95.0
		_eng_phase = fmod(_eng_phase + f0 * dt, 1.0)
		var eng := 0.0
		if _eng_amp > 0.001:
			# Pulse-ish firing with harmonics; a little noise for the exhaust.
			var ph := _eng_phase
			eng = (sin(ph * TAU) * 0.6 + sin(ph * TAU * 2.0) * 0.35 + sin(ph * TAU * 3.0) * 0.2 + (1.0 if ph < 0.15 else -0.25) * 0.3) * _eng_amp
			eng += (_rng.randf() * 2.0 - 1.0) * 0.08 * _eng_amp
		# --- wind ---
		_wind_amp += (wind_target - _wind_amp) * smooth
		var white := _rng.randf() * 2.0 - 1.0
		_wind_lp += (white - _wind_lp) * 0.08
		_wind_lp2 += (_wind_lp - _wind_lp2) * 0.04
		var wind := _wind_lp2 * 3.0 * _wind_amp
		# --- footsteps ---
		var step := 0.0
		if step_period > 0.0:
			_step_timer -= dt
			if _step_timer <= 0.0:
				_step_timer = step_period
				_step_env = clampf(0.25 + foot_speed * 0.08, 0.3, 0.8)
		if _step_env > 0.001:
			_step_lp += (white - _step_lp) * 0.35
			step = _step_lp * _step_env
			_step_env *= 0.9985
		# --- birds (day) and crickets (night) ---
		var nature := 0.0
		if night:
			_cricket_gate += dt
			var cyc := fmod(_cricket_gate, 1.1)
			if cyc < 0.6:
				_cricket_phase = fmod(_cricket_phase + 4200.0 * dt, 1.0)
				var mod := 0.5 + 0.5 * sin(cyc * TAU * 28.0)
				nature = sin(_cricket_phase * TAU) * mod * 0.05
		else:
			_bird_timer -= dt
			if _bird_timer <= 0.0:
				_bird_timer = _rng.randf_range(2.5, 7.0)
				var notes := _rng.randi_range(2, 5)
				for k in notes:
					_bird_notes.append([_rng.randf_range(2200.0, 3800.0), int(RATE * _rng.randf_range(0.04, 0.09)), _rng.randf_range(-18.0, 18.0)])
					_bird_notes.append([0.0, int(RATE * 0.035), 0.0])  # gap
			if not _bird_notes.is_empty():
				var note: Array = _bird_notes[0]
				if note[0] > 0.0:
					_bird_phase = fmod(_bird_phase + note[0] * dt, 1.0)
					note[0] += note[2]
					nature = sin(_bird_phase * TAU) * 0.06
				note[1] -= 1
				if note[1] <= 0:
					_bird_notes.pop_front()
		# --- skid ---
		_skid_env += (skid_target - _skid_env) * fast
		var skid := 0.0
		if _skid_env > 0.001:
			_skid_lp += (white - _skid_lp) * 0.3
			skid = (white - _skid_lp) * 0.6 * _skid_env
		# --- horn ---
		_horn_env += (horn_target - _horn_env) * fast
		var horn := 0.0
		if _horn_env > 0.001:
			_horn_phase1 = fmod(_horn_phase1 + 400.0 * dt, 1.0)
			_horn_phase2 = fmod(_horn_phase2 + 500.0 * dt, 1.0)
			var h := sin(_horn_phase1 * TAU) + sin(_horn_phase2 * TAU) + 0.4 * sin(_horn_phase1 * TAU * 3.0)
			horn = clampf(h * 0.8, -1.0, 1.0) * 0.5 * _horn_env
		var others := 0.0
		for k in range(_ai_horns.size() - 1, -1, -1):
			var hn: Array = _ai_horns[k]
			hn[2] = fmod(hn[2] + hn[4] * dt, 1.0)
			hn[3] = fmod(hn[3] + hn[4] * 1.25 * dt, 1.0)
			others += clampf(sin(hn[2] * TAU) + sin(hn[3] * TAU), -1.0, 1.0) * hn[1]
			hn[0] -= 1
			if hn[0] <= 0:
				_ai_horns.remove_at(k)
		var s := eng + wind + step + nature + skid + horn + others
		s = clampf(s, -1.0, 1.0)
		out[i] = Vector2(s, s)
	return out
