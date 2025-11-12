-- == Vanilla ==--

if data.raw["space-location"]["shattered-planet"] then
	data.raw["space-location"]["shattered-planet"].redrawn_connections_exclude = true
end
if data.raw["space-location"]["solar-system-edge"] then
	data.raw["space-location"]["solar-system-edge"].redrawn_connections_length_multiplier = 4.8
end
if data.raw["space-location"]["solar-system-edge"] then
	data.raw["space-location"]["shattered-planet"].redrawn_connections_length_multiplier = 100 -- Has no effect in vanilla
end
