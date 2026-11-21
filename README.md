# Ragdolls

  When a player or a mob dies, its body falls as a physics ragdoll. This replaces
the death animation, the tipping over, the fading or the vanishing it would
otherwise do.
  It works in any game and needs no setup per mob. The mod reads each mob's model
file (`.b3d`, `.gltf` or `.glb`) and works out a rig from its bones: the torso,
plus the limbs hanging off it (legs, arms, wings, tails, heads, two-segment
legs, armor overlays). Models without bones, and cube or sprite mobs, fall as
rigid bodies.

## Supported

| Players in any game (Minetest Game, VoxeLibre, MineClone2, Mineclonia, Exile, CTF...) | Skins, armor and held items come along. The real body is hidden until respawn. |
| Mobs Redo (`mobs`), with mobs_animal, mobs_monster and other packs | `death_anim` is replaced. Drops, sounds, `on_die` and `on_death` still run. |
| mcl_mobs (VoxeLibre, MineClone2, Mineclonia) | The death is made instant (drops, xp, sounds and awards all run). The tip-over and smoke are skipped. |
| mobkit | `mobkit.hq_die` is replaced. |
| mob_core | `mob_core.on_die` is replaced. Drops and the death sound still run. |
| Creatura (Animalia and others) | Animalia's die utility is replaced. Any other Creatura mob that falls over gets a ragdoll, and its real body is hidden. |

The killing punch decides which way the body goes and how hard. It is recorded
for every entity and player.


`/ragdolls` shows how many bodies there are and what they cost.
`/ragdolls clear` removes them all (needs the `server` privilege).

## For modders

```lua
-- Opt a mob out, in its entity definition:
_ragdoll = false

-- Or from another mod, by entity name or mesh file:
ragdolls.exclude("mymod:boss")
ragdolls.register_profile("mymod:golem", {
	rigid_only = true,                 -- fall as one stiff body
	skip_bones = {Antenna = true},     -- don't flop these
	max_angle = {Head = 0.4},          -- how far a limb may swing (radians)
	frame = 0,                         -- animation frame to freeze the body at
})

-- Make a ragdoll yourself (the object must still exist). Do it before your
-- death code changes the object, then remove the object:
ragdolls.spawn_from(obj, {hit = {dir = dir, power = 4}})
-- or in two steps:
local snap = ragdolls.snapshot(obj, {frame = 0, texture_mod = "", strip = "^[colorize:#ff0000:100"})
obj:remove()
ragdolls.spawn(snap)

-- A game with its own player deaths can turn the player hook off:
ragdolls.players_disabled = true

ragdolls.register_on_spawn(function(ragdoll, snapshot, source) end)
ragdolls.body_pos(ragdoll)                 -- where the body is (e.g. for death cams)
ragdolls.hide_player(player); ragdolls.show_player(player)
```
## Limits

- Needs Luanti 5.9 or newer (bone overrides).
- Limbs are found for `.b3d`, `.gltf` and `.glb` models. `.x` and `.obj` mobs
  fall as rigid bodies.
- Bodies don't collide with players or other bodies, and they aren't saved when
  their area unloads.
- A mob whose death code does something special (it explodes, splits, or turns
  into something else) may need `_ragdoll = false` or a profile.
