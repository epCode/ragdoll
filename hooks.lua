-- Hooks into the mob APIs. Each one keeps everything the API does at death
-- (drops, xp, sounds, callbacks, kill credit) and replaces only the visual
-- part: the death animation, tipping over, fading, smoke - with a ragdoll.
local R = ragdolls

local function mod(name) return core.get_modpath(name) ~= nil end

-- The frame to freeze the body at: the mob's standing pose.
local function stand_frame(le)
	local a = le.animation or le.animations
	if type(a) ~= "table" then return nil end
	if a.stand_start then return a.stand_start end                         -- mobs redo / mcl_mobs
	local s = a.stand or a.idle
	if type(s) == "table" then
		if s.range then return s.range.x end                                 -- mobkit / creatura
		if s.x then return s.x end                                           -- all_mobs_api
	end
	return nil
end
R.stand_frame = stand_frame

local function is_api_mob(def) return def and rawget(def, "_ragdolls_api") end

core.register_on_mods_loaded(function()
	----------------------------------------------------------------------------
	-- Every entity: remember the punch that might kill it (direction, strength)
	----------------------------------------------------------------------------
	for name, def in pairs(core.registered_entities) do
		if not name:find("^ragdolls:") and not name:find("^__builtin") then
			local own = rawget(def, "on_punch")
			local mt = getmetatable(def)
			def.on_punch = function(self, puncher, tflp, caps, dir, damage, ...)
				if dir and self.object then R.note_hit(self.object, dir, damage, caps) end
				local f = own
				if not f then
					local idx = mt and mt.__index
					f = type(idx) == "table" and idx.on_punch or nil
				end
				if f then return f(self, puncher, tflp, caps, dir, damage, ...) end
			end
		end
	end

	----------------------------------------------------------------------------
	-- Mobs Redo
	----------------------------------------------------------------------------
	local mobs = rawget(_G, "mobs")
	if mobs and type(mobs.mob_class) == "table" and mobs.mob_class.check_for_death then
		local mc = mobs.mob_class
		local orig_check, orig_anim = mc.check_for_death, mc.death_anim
		mc.check_for_death = function(self, cause, ...)
			local snap
			if self.state ~= "die" and (self.health or 1) <= 0 and not self._ragdolled and R.enabled_for(self) then
				snap = R.snapshot(self.object, {frame = stand_frame(self), texture_mod = self.texture_mods})
			end
			self._ragdolls_snap = snap
			local r = orig_check(self, cause, ...)
			-- gone already (its on_die / on_death removed it): the body falls now
			if snap and not self._ragdolled and not self.object:get_pos() then
				self._ragdolled = true
				R.spawn(snap)
			end
			self._ragdolls_snap = nil
			return r
		end
		mc.death_anim = function(self, ...)
			local snap = self._ragdolls_snap
			if snap and not self._ragdolled then
				self._ragdolled = true
				R.spawn(snap, self.object)
				if mobs.remove then mobs:remove(self, true) else self.object:remove() end
				return true    -- (no smoke, no death animation)
			end
			return orig_anim(self, ...)
		end
		for _, def in pairs(core.registered_entities) do
			local mt = getmetatable(def)
			if mt and mt.__index == mc then def._ragdolls_api = true end
		end
		core.log("action", "[ragdolls] hooked Mobs Redo")
	end

	----------------------------------------------------------------------------
	-- mcl_mobs (VoxeLibre, MineClone2, Mineclonia)
	----------------------------------------------------------------------------
	local mcl_mobs = rawget(_G, "mcl_mobs")
	if mcl_mobs and type(mcl_mobs.mob_class) == "table" and mcl_mobs.mob_class.check_for_death then
		local mc = mcl_mobs.mob_class
		local orig = mc.check_for_death
		local quiet = false
		mc.check_for_death = function(self, ...)
			local dying = (self.health or 1) <= 0 and self.state ~= "die" and not self.dead and not self._ragdolled
				and R.enabled_for(self)
			if not dying then return orig(self, ...) end
			local snap = R.snapshot(self.object, {frame = stand_frame(self), strip = "^[colorize:#d42222:175"})
			-- an instant death: drops, xp, sounds and callbacks now, no tipping over
			local had = rawget(self, "instant_death")
			self.instant_death = true
			quiet = true
			local ok, r = pcall(orig, self, ...)
			quiet = false
			self.instant_death = had
			if not ok then error(r, 0) end
			if (self.dead or self.state == "die" or not self.object:get_pos()) and not self._ragdolled then
				self._ragdolled = true
				R.spawn(snap, self.object)
				-- (Mineclonia removes it on its next step)
				if self.object:get_pos() then R.hide_object(self.object) end
			end
			return r
		end
		local effect = mcl_mobs.death_effect
		if effect then
			mcl_mobs.death_effect = function(...)
				if quiet then return end    -- (the smoke puff of a vanishing body)
				return effect(...)
			end
		end
		for _, def in pairs(core.registered_entities) do
			local mt = getmetatable(def)
			if mt and mt.__index == mc then def._ragdolls_api = true end
		end
		core.log("action", "[ragdolls] hooked mcl_mobs")
	end

	----------------------------------------------------------------------------
	-- mob_core (on mobkit): its own death sequence
	----------------------------------------------------------------------------
	local mob_core = rawget(_G, "mob_core")
	local mobkit = rawget(_G, "mobkit")
	if mob_core and mobkit and mob_core.on_die then
		local orig = mob_core.on_die
		mob_core.on_die = function(self, ...)
			if self._ragdolled or not R.enabled_for(self) then return orig(self, ...) end
			self._ragdolled = true
			local snap = R.snapshot(self.object, {frame = stand_frame(self)})
			if self.driver and mob_core.force_detach then mob_core.force_detach(self.driver) end
			self.owner = nil
			if self.sounds and self.sounds.death and mob_core.make_sound then mob_core.make_sound(self, "death") end
			self.logic = function() end
			mobkit.queue_high(self, function(s)
				if not mobkit.exists(s) then return true end
				if s.driver and mob_core.force_detach then mob_core.force_detach(s.driver) end
				if mob_core.item_drop then mob_core.item_drop(s) end
				R.spawn(snap, s.object)
				s.object:remove()
				return true
			end, 100)
		end
		core.log("action", "[ragdolls] hooked mob_core")
	end

	----------------------------------------------------------------------------
	-- mobkit: hq_die (fall over, wait, vanish)
	----------------------------------------------------------------------------
	if mobkit and mobkit.hq_die then
		local orig = mobkit.hq_die
		mobkit.hq_die = function(self, ...)
			if self._ragdolled or not R.enabled_for(self) then return orig(self, ...) end
			self._ragdolled = true
			local snap = R.snapshot(self.object, {frame = stand_frame(self)})
			self.logic = function() end
			mobkit.queue_high(self, function(s)
				if not mobkit.exists(s) then return true end
				R.spawn(snap, s.object)
				s.object:remove()
				return true
			end, 100)
		end
		for _, def in pairs(core.registered_entities) do
			if def.on_step == mobkit.stepfunc then def._ragdolls_api = true end
		end
		core.log("action", "[ragdolls] hooked mobkit")
	end

	----------------------------------------------------------------------------
	-- Creatura (Animalia and others)
	----------------------------------------------------------------------------
	local creatura = rawget(_G, "creatura")
	if creatura then
		-- Animalia's death: sound, fall over, wait, smoke, drops, vanish
		if creatura.registered_utilities and creatura.registered_utilities["animalia:die"] then
			creatura.register_utility("animalia:die", function(self)
				local snap = not self._ragdolled and R.enabled_for(self)
					and R.snapshot(self.object, {frame = stand_frame(self)}) or nil
				self:set_utility(function(m)
					local pos = m.object:get_pos()
					if not pos then return end
					local s = m.sounds and m.sounds.death
					if s and s.name then
						core.sound_play(s.name, {pos = pos, gain = s.gain or 1, max_hear_distance = s.distance or 16}, true)
					elseif m.play_sound then
						m:play_sound("death")
					end
					if creatura.drop_items then creatura.drop_items(m) end
					if snap and not m._ragdolled then
						m._ragdolled = true
						R.spawn(snap, m.object)
					end
					m.object:remove()
				end)
			end)
		end
		-- anything else falling over the Creatura way: ragdoll now, the real
		-- body is hidden and the mob's own code removes it later
		if creatura.action_fallover then
			local orig = creatura.action_fallover
			creatura.action_fallover = function(self, ...)
				if not self._ragdolled and R.enabled_for(self) then
					self._ragdolled = true
					R.spawn_from(self.object, {frame = stand_frame(self)})
					R.hide_object(self.object)
				end
				return orig(self, ...)
			end
		end
		for _, def in pairs(core.registered_entities) do
			local mt = getmetatable(def)
			local idx = mt and mt.__index
			if type(idx) == "table" and rawget(idx, "_execute_utilities") then def._ragdolls_api = true end
		end
		core.log("action", "[ragdolls] hooked Creatura")
	end

	----------------------------------------------------------------------------
	-- all_mobs_api: die() rolls the body over or plays "die", then vanishes
	----------------------------------------------------------------------------
	local amapi = rawget(_G, "all_mobs_api")
	if amapi and type(amapi.registered_mobs) == "table" then
		for name in pairs(amapi.registered_mobs) do
			local proto = core.registered_entities[name]
			if proto and proto.die then
				local orig_die = proto.die
				proto.die = function(self, cause, source, ...)
					if self._dead or self._ragdolled or not R.enabled_for(self) then
						return orig_die(self, cause, source, ...)
					end
					local o = self.object
					local snap = R.snapshot(o, {frame = stand_frame(self.def or self)})
					local r = orig_die(self, cause, source, ...)    -- goals, sound, on_death, drops
					if o:get_pos() and not self._ragdolled then
						self._ragdolled = true
						R.spawn(snap, o)
						o:remove()
					end
					return r
				end
				proto._ragdolls_api = true
			end
		end
		core.log("action", "[ragdolls] hooked all_mobs_api")
	end

	----------------------------------------------------------------------------
	-- Anything else the engine kills (hp reaches 0): plain mesh mobs
	----------------------------------------------------------------------------
	for name, def in pairs(core.registered_entities) do
		local ip = def.initial_properties or def
		if not name:find("^ragdolls:") and not name:find("^__builtin") and not is_api_mob(def)
				and (ip.visual == "mesh" or ip.visual == "cube") and (ip.hp_max or 1) > 1 then
			local own = rawget(def, "on_death")
			def.on_death = function(self, killer, ...)
				if not self._ragdolled and R.enabled_for(self) then
					self._ragdolled = true
					R.spawn_from(self.object)
				end
				if own then return own(self, killer, ...) end
			end
		end
	end
end)
