for _, prototype in pairs({ "space-location", "planet" }) do
	for _, loc in pairs(data.raw[prototype]) do
		if loc.subgroup and loc.subgroup == "satellites" then
			loc.redrawn_connections_exclude = true
		elseif loc.hidden then
			loc.redrawn_connections_exclude = true
		end
	end
end

for _, connection in pairs(data.raw["space-connection"]) do
	if connection.hidden then
		connection.redrawn_connections_exclude = true
	end
end

-- == Vanilla ==--
if data.raw["space-location"]["shattered-planet"] then
	data.raw["space-location"]["shattered-planet"].redrawn_connections_exclude = true
end
if data.raw["space-location"]["solar-system-edge"] then
	data.raw["space-location"]["solar-system-edge"].redrawn_connections_length_multiplier = 4.8
end

-- == Maraxsis ==--

if data.raw.planet["maraxsis-trench"] then
	data.raw.planet["maraxsis-trench"].redrawn_connections_exclude = true
end
