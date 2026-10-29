# Combo Spells

No wizard is born with a combo spell. They're the strongest spells in the game: almost all of
them kill whatever they touch, and most summon something that keeps fighting after you've
cast it. Each one takes two schools of magic working together, so the usual way to get one is
to find the right teammate and beat your staves together.

- [The eight combos](#the-eight-combos)
- [Earning one: the staff clash](#earning-one-the-staff-clash)
- [Finding one: spellbooks](#finding-one-spellbooks)
- [Casting](#casting)
- [The spells](#the-spells)
- [For server admins](#for-server-admins)

## The eight combos

| Combo | Elements |
|---|---|
| [Ball Lightning](#ball-lightning) | Fire + Lightning |
| [Meteor](#meteor) | Fire + Death |
| [Lightning Cloud](#lightning-cloud) | Ice + Lightning |
| [Giant Plant](#giant-plant) | Ice + Nature |
| [Spirit Wizard](#spirit-wizard) | Life + Nature |
| [Wally the Wombat](#wally-the-wombat) | Life + Earth |
| [Tornado](#tornado) | Earth + Wind |
| [Raise Dead](#raise-dead) | Death + Wind |

Or by class:

| | Fire | Ice | Lightning | Earth | Wind | Nature | Life | Death |
|---|---|---|---|---|---|---|---|---|
| **Fire** | | | Ball Lightning | | | | | Meteor |
| **Ice** | | | Lightning Cloud | | | Giant Plant | | |
| **Lightning** | Ball Lightning | Lightning Cloud | | | | | | |
| **Earth** | | | | | Tornado | | Wombat | |
| **Wind** | | | | Tornado | | | | Raise Dead |
| **Nature** | | Giant Plant | | | | | Spirit Wizard | |
| **Life** | | | | Wombat | | Spirit Wizard | | |
| **Death** | Meteor | | | | Raise Dead | | | |

Every class except the Archmage is in exactly two recipes. The original mod had two more that
needed its dragon wizard, a class this port doesn't have: a second route to Raise Dead
(Dragon + Death) and Spirit of the Dragon (Dragon + Wind).

## Earning one: the staff clash

1. **Find a teammate whose element makes a combo with yours.** It has to be a teammate:
   there's no clashing in free-for-all.
2. **Both of you take out your staves** (slot 1).
3. **Hit each other with them.** A clash rings out instead of doing damage. Keep going.
4. **Once you've both landed more than five clashes,** the next one hands a combo spell to
   whoever swung it. *"Your staves spark: you have learned Meteor!"*

Things worth knowing:

- Your partner has to be holding their staff when you hit them. Hitting a teammate who has a
  spell out is just a staff hit.
- Hitting anything that isn't a clash (an enemy, a wall, a teammate who can't combo with you)
  resets your count to zero.
- Whoever got the spell can't clash again for the rest of that life. Their partner goes back
  to zero and can earn one of their own, but they'll need a different teammate to do it.
- It's a two-person job that leaves you both standing still with staves out. Do it somewhere
  safe, or have someone watch the door.

## Finding one: spellbooks

A combo spell can also be lying on the ground as a spinning spellbook. Walk over it to learn
the spell. A book you already carry stays on the ground for someone else.

A map can place spellbooks itself, holding a particular spell or a random one. A map can also
ask for **combo chaos**, which turns its leftover Half-Life/TFC weapon and ammo pickups into
random combo spellbooks (re-rolled each time they respawn) and makes TFC resupply backpacks
hand out a combo spell. None of the maps in the current rotation do either, but a server
admin can switch combo chaos on anywhere. See [For server admins](#for-server-admins).

## Casting

A combo spell goes into your spell slots like any other. Each one:

- **costs no mana,**
- **casts once.** A successful cast uses the spell up, and another means earning or finding it
  again,
- **lasts until you die,** so don't sit on it too long.

Most combos are only used up when they work. Two are different. **Meteor** is spent even when
there's nobody to hit. **Raise Dead** refuses to go off when there's nothing to raise, so you
keep it.

Once cast, the summons belong to the world, not to you. Dying, changing class or leaving the
server doesn't take them back. They run until their timer ends or something kills them.

## The spells

### Ball Lightning

*Fire + Lightning.* "A powerful burst of lightning will swiftly strike down your foes."

Two spells in one. First an instant bolt for **500**, across the whole map, wherever you
aim. Then a ball of lightning is left standing where the bolt landed. For 30 seconds it drifts
at the nearest enemy it can see and kills on contact (600). With nobody in view it wanders the
room looking for someone, so a crater is not a safe place to stand. The cast shakes the screen
of everyone within 25 m.

### Meteor

*Fire + Death.* "A destructive spell that will call burning rocks from the sky to crush your
target."

Picks the nearest enemy you can see in front of you, out to 51 m, and calls **three meteors**
down on them from three directions. The meteors pass through walls and steer the whole way
in, timed to land together as a single blow of **600** within 5 m. You can't dodge it. All the
target gets is the couple of seconds it takes to arrive: three smoke trails converging on
them, and a chance to be somewhere else. Cast with nobody in view, it's wasted: the book is
spent on the sound of a miss.

### Lightning Cloud

*Ice + Lightning.* "Creates a thundercloud that will shock enemies it meets as it moves away
from you."

A slow thundercloud that drifts away from you in a dead straight line, in whatever direction
you were looking. It never turns and never hunts, so aiming it is the whole of casting it. On
the way it zaps whichever enemy it can see for **80** every half second. The first wall or
body it runs into takes **600** and ends the cloud, and otherwise it lasts about a minute. Send
it down a corridor or across a courtyard and it holds that ground.

### Giant Plant

*Ice + Nature.* "This plant is carnivorous and will feast on any foes that come near to it."

Grows a lumbering carnivorous plant on the ground 3 m ahead of you. It stalks the nearest enemy
it can see, and its bite kills outright (600). It has 250 health, regrows 20 every
5 seconds, and lasts a minute. Nothing but your supply of books limits how many you can have
out at once.

### Spirit Wizard

*Life + Nature.* "Summons a spirit from death to aid you in your battles."

The ghost of a wizard, wailing, left hanging in the air in front of you. It drifts where you
left it until it sees someone, then stares them down and flies at them. Its stare is a beam of
20 every tenth of a second at anything in front of it, out to 25 m. Catching someone does 600
and costs the spirit 200 of its own 600 health, so it can take three wizards with it at most.

It's the only combo summon that can be killed, and the only one that has to be looking at
you. Get behind it and it doesn't know you're there. Shoot it and it turns to face you, which
is usually the last thing you want. Lasts 30 seconds.

### Wally the Wombat

*Life + Earth.* "He may look funny, but Wally packs a punch and can also heal team-mates."

Thrown underarm, Wally lands running and spends 40 seconds leaping at whoever he can see. An
enemy he lands on gets bitten for **100**. A teammate he lands on gets healed for **200**,
which also cures poison and burning. He's the only summon that does anything for your own
side, so throw him into a fight rather than at one person, because you don't get to choose who
he jumps at next. He has 1000 health, and hurting him makes it personal: he drops whatever he
was chasing and goes for whoever hit him.

### Tornado

*Earth + Wind.* "Creates a whirling vortex of air that will rip any enemies off their feet."

A whirlwind that drifts out of your hands, turns toward the nearest enemy it can see, and
grinds along the ground for 30 seconds. Nothing can hurt it, and it moves faster than half a
wizard's top speed, so the only way out is to outrun it. Anyone it passes over is ground down
and flung into the air, and the fall is as dangerous as the wind. It keeps throwing the bodies
of whatever it kills.

### Raise Dead

*Death + Wind.* "Will turn nearby corpses into an army of skeletal warriors."

Goes off where you stand and takes every body within 10 m. Enemy wizards it can see are killed
outright and dragged back up as skeletons fighting for you. Any corpse already lying there
gets raised the same way. Skeletons have 200 health, walk at a man's pace and throw bones at
whatever they see. They have no timer and fight until something kills them or the round ends.

It's the only spell that gets stronger the worse a fight has gone. With nothing to raise it
refuses ("There are no bodies here to raise!") and you keep the book. Someone standing right
over a body (within about a metre) stops the whole cast.

## For server admins

| Command | What it does |
|---|---|
| `/allow_combos on\|off` | Whether teammates can earn combos by clashing staves (on by default). |
| `/combo_chaos auto\|on\|off` | `auto` (the default) follows the map. `on` turns every map's weapon and ammo pickups into random combo spellbooks, and `off` never does. |
| `/spawn combo_weapon` | Drops a spellbook holding a random combo spell in front of you. `/spawn meteor_weapon` and so on drop a particular one. |
| `/give meteor_weapon` | Puts a combo spell straight into your own spell slots. |

The spell names for `/spawn` and `/give` are `ball_lightning_weapon`, `meteor_weapon`,
`lightning_cloud_weapon`, `giant_plant_weapon`, `spirit_wiz_weapon`, `wombat_weapon`,
`tornado_weapon` and `raise_dead_weapon`.
