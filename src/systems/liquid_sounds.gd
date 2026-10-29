class_name LiquidSounds
extends Object
## The noise something makes going into a pool: a skull plops, a wizard whumps, a dragon lands
## like a dropped car. One bank of clips for all of it — size is carried by volume and pitch
## rather than by a clip per thing, so a new falling body needs a number, not an asset.
##
## Nothing in the repo splashes today, players included (water entry is silent in netmove), so
## this deliberately sits outside the corpse that first needed it.

## Clips per liquid. Lava has no entry: nothing shipped hisses, and a plop into magma is worse
## than silence. Slime shares the water bank — it is water with a colour, both here and in the
## movement code.
const SPLASH := {
	GameConsts.Liquid.WATER: ["misc/splash1.wav", "misc/splash2.wav"],
	GameConsts.Liquid.SLIME: ["misc/splash1.wav", "misc/splash2.wav"],
}

const MIN_SPEED := 1.5     # below this something is drifting in, not falling in
## What a corpse actually arrives at: a body falls into a pool from a few metres, not from the
## sky. Set to the speed of a 2m drop, so an ordinary fall is already at full volume and only a
## short slump off a ledge is quieter.
const FULL_SPEED := 7.0
const FLOOR := 0.5         # quietest entry, as a fraction of full volume
const GAIN := 2.5          # how much louder than the clip's own level a body-sized splash is
## Loudness is clamped either side so a gib cannot vanish and a dragon cannot clip the mix.
const MIN_LOUDNESS := 0.4
const MAX_LOUDNESS := 3.5


## Splash at `pos` — which is where the thing was last seen ABOVE the surface, not where it is
## now, so the sound comes off the water rather than from under it.
##
## `size` is the body against the water: 1.0 is a person, and pitch runs inversely from it (a
## small thing plops high, a big one thuds). `broadcast` is the usual split — false when every
## peer runs the same fall and would sound it for itself, true when only the host can see it.
##
## Returns whether anything played, so a caller can latch on the entry rather than on the noise.
static func splash(pos: Vector3, liquid: GameConsts.Liquid, size: float,
		speed: float, rng: RandomNumberGenerator, broadcast := false) -> bool:
	var clips: Array = SPLASH.get(liquid, [])
	if clips.is_empty() or speed < MIN_SPEED:
		return false
	var path: String = clips[rng.randi() % clips.size()]
	# sqrt, not size itself: a skull is a third of a wizard by volume but nothing like a third
	# as loud, and taken straight it came out as a tick you had to be told to listen for.
	var loudness := clampf(GAIN * sqrt(size) * clampf(speed / FULL_SPEED, FLOOR, 1.0),
		MIN_LOUDNESS, MAX_LOUDNESS)
	# Held under 1.3 at the top: past that the clip is short and thin enough that a plop stops
	# reading as water at all.
	var pitch := clampf(1.0 / sqrt(maxf(size, 0.01)), 0.65, 1.3) * rng.randf_range(0.94, 1.06)
	# A bigger splash carries further — but nothing ever carries LESS far than a room. SoundSystem
	# scales the full-volume radius off max_dist, so shortening it makes a small splash quiet up
	# close as well as far away, which is most of why the skull could not be heard.
	var max_dist := SoundSystem.DEFAULT_MAX_DIST * clampf(size, 1.0, 2.0)
	if broadcast:
		SoundSystem.play_3d(path, pos, pitch, linear_to_db(loudness), max_dist)
	else:
		SoundSystem.play_3d_local(path, pos, pitch, linear_to_db(loudness), max_dist)
	return true
