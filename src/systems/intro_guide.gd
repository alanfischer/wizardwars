extends Object
## The newcomer's controls card, shown once before the map description the first time this
## install starts a game. The "seen it" flag lives in the [intro] section of settings.cfg —
## the same file the renderer, picture quality and mouse settings use:
##
##     [intro]
##     show=false
##
## The lobby exposes it as a tick so it can be turned back on, and /intro re-shows the card
## without touching the flag.
##
## No class_name — preloaded by its consumers; see README, "class_name and preload".

const KeyBindings = preload("res://src/systems/key_bindings.gd")

const SETTINGS_PATH := "user://settings.cfg"  # shared with LobbyUI, InputSettings, RenderQuality
const SECTION := "intro"

const TITLE := "Welcome to Wizard Wars"

## Long enough to read the whole card at a comfortable pace; any key cuts it short, and scrolling
## cancels the auto-hide outright (see HUD._motd_scroll_by).
const HOLD := 30.0

## Every key this names is a placeholder, filled from the live bindings at the moment the card is
## shown — a player who has been through the Controls screen is the one who most needs the card to
## be telling the truth.
const KEYBOARD_TEMPLATE := """{team} picks your team, {class} picks your wizard. Both menus reopen with those keys.

MOVING
  {move} walks, the mouse looks, {jump} jumps, {duck} ducks, {walk} walks slowly.
  In water, aim where you want to go and hold forward.

CASTING
  {attack} casts the spell in your hands — hold it down for the ones that charge or stream.
  {attack2} is that spell's other mode, when it has one.
  {slot_first} to {slot_last} pick a spell, {prev} and {next} cycle them, {last} flicks back to the last one.
  Spells cost mana, and mana does NOT come back on its own: walk over the packs and backpacks around the map to refill, and over spellbooks to learn new spells.

SATCHELS
  Hold {satchel} to light the fuse, release to throw. The fuse burns while you hold it, so a quick tap lobs a bomb that goes off downrange and a long hold drops one at your own feet.

USING THINGS
  {use} is your hand. Point at a door, a button or a lever and press {use}.
  Walk up to a dragon and press {use} to climb on. Up there {attack} breathes fire, and the mana bar becomes your flame. Press {use} again to get down.

TALKING
  {chat} chats to everyone, {team_chat} only to your team, {console} starts a command (/help lists them).
  {help} calls a teammate for a heal. Hold {scoreboard} for the scoreboard.

Any key closes this. /intro brings it back."""

const VR_TEXT := """The lobby panel picks your team and wizard; the buttons under your move thumbstick reopen it.

CAST HAND (your right hand, or your left if you set left-handed)
  Trigger casts the spell in your hand — hold it for the ones that charge or stream.
  Grip is that spell's other mode. Push the thumbstick left or right to snap-turn, forward or back to cycle spells. A/X uses things, B/Y jumps.

MOVE HAND
  Thumbstick walks. Click it to duck. X/A opens the wizard menu, Y/B the team menu.

WHAT TO POINT AT
  Doors, buttons and levers all answer to the use button — walk up and press it.
  So do dragons: press use beside one to climb on, cast to breathe fire, use again to get off.

Spells cost mana, and mana does not come back on its own — walk over the packs and backpacks around the map to refill, and over spellbooks to learn new spells.

Any key closes this. /intro brings it back."""


## The card body, phrased for whichever set of controls the player is actually holding.
static func body(is_vr: bool) -> String:
	return VR_TEXT if is_vr else _keyboard_text()


## "W A S D" when the defaults are in force, and whatever four keys replaced them when they are not.
static func _move_keys() -> String:
	var parts := PackedStringArray()
	for action in ["move_forward", "move_left", "move_back", "move_right"]:
		parts.append(KeyBindings.display_for(action))
	return " ".join(parts)


static func _keyboard_text() -> String:
	return KEYBOARD_TEMPLATE.format({
		"team": KeyBindings.display_for("team_menu"),
		"class": KeyBindings.display_for("class_menu"),
		"move": _move_keys(),
		"jump": KeyBindings.display_for("jump"),
		"duck": KeyBindings.display_for("crouch"),
		"walk": KeyBindings.display_for("walk"),
		"attack": KeyBindings.display_for("attack"),
		"attack2": KeyBindings.display_for("attack2"),
		"slot_first": KeyBindings.display_for("slot1"),
		"slot_last": KeyBindings.display_for("slot%d" % KeyBindings.SLOT_COUNT),
		"prev": KeyBindings.display_for("weapon_prev"),
		"next": KeyBindings.display_for("weapon_next"),
		"last": KeyBindings.display_for("lastweapon"),
		"satchel": KeyBindings.display_for("satchel"),
		"use": KeyBindings.display_for("use"),
		"chat": KeyBindings.display_for("chat"),
		"team_chat": KeyBindings.display_for("chat_team"),
		"console": KeyBindings.display_for("console"),
		"help": KeyBindings.display_for("callhelp"),
		"scoreboard": KeyBindings.display_for("scoreboard"),
	})


static func should_show() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return true  # no settings file at all: this really is a first run
	return bool(cfg.get_value(SECTION, "show", true))


static func set_show(show: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # load existing; OK if missing
	cfg.set_value(SECTION, "show", show)
	cfg.save(SETTINGS_PATH)
