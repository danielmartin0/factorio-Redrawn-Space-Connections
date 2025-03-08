local asteroid_util = require("__space-age__.prototypes.planet.asteroid-spawn-definitions")

local saved_asteroid_definitions = {}
data.raw.planet.nauvis.hidden = true
data.raw.planet.nauvis.map_gen_settings = nil

local SCALE_FACTOR = 1250 -- Matches the scale in Cosmic-Social-Distancing
local REAL_SPACE = settings.startup["Redrawn-Space-Connections-real-space-triangulation"].value

local function connection_length(from_name, to_name)
	local from_planet = data.raw.planet[from_name] or data.raw["space-location"][from_name]
	local to_planet = data.raw.planet[to_name] or data.raw["space-location"][to_name]

	if not from_planet or not to_planet then
		log(string.format("Redrawn Space Connections: Connection %s to %s has invalid planets", from_name, to_name))
		return nil
	end

	-- Factorio currently uses linear paths in polar co-ordinates.

	if
		from_planet.distance == to_planet.distance
		and (from_planet.orientation == to_planet.orientation or from_planet.distance == 0)
	then
		return 1 -- because 0 breaks the game
	end

	local angle1 = (from_planet.orientation % 1) * 2 * math.pi
	local angle2 = (to_planet.orientation % 1) * 2 * math.pi
	local r1 = from_planet.distance or 0
	local r2 = to_planet.distance or 0
	local angle_diff = math.abs(angle2 - angle1)

	if r1 > r2 then
		r1, r2 = r2, r1
		angle1, angle2 = angle2, angle1
	end

	local path_length

	if angle_diff < 1e-6 then
		path_length = math.abs(r2 - r1)
	elseif math.abs(r2 - r1) < 1e-6 then
		path_length = r1 * angle_diff
	else
		local b = math.abs((angle2 - angle1) / (r2 - r1))

		if math.abs(b) < 1e-6 then
			path_length = math.sqrt((r2 - r1) * (r2 - r1) + (r1 * angle_diff) * (r1 * angle_diff))
		else
			local term1 = b * (-r1 * math.sqrt(1 + b * b * r1 * r1) + r2 * math.sqrt(1 + b * b * r2 * r2))
			local term2 = math.log(-b * r1 + math.sqrt(1 + b * b * r1 * r1))
			local term3 = -math.log(-b * r2 + math.sqrt(1 + b * b * r2 * r2))

			path_length = (term1 + term2 + term3) / (2 * b)
		end
	end

	local multiplier = 1

	if from_planet.redrawn_connections_length_multiplier then
		multiplier = math.max(multiplier, from_planet.redrawn_connections_length_multiplier)
	end
	if to_planet.redrawn_connections_length_multiplier then
		multiplier = math.max(multiplier, to_planet.redrawn_connections_length_multiplier)
	end

	return path_length * SCALE_FACTOR * multiplier
end

local function snap_length(length)
	return math.ceil(length / 1000) * 1000
end

local fixed_edges = {}
if data.raw["space-connection"] then
	for name, connection in pairs(data.raw["space-connection"]) do
		local from_loc = data.raw["planet"][connection.from] or data.raw["space-location"][connection.from]
		local to_loc = data.raw["planet"][connection.to] or data.raw["space-location"][connection.to]

		if from_loc and to_loc then
			if
				from_loc.redrawn_connections_keep
				or to_loc.redrawn_connections_keep
				or connection.redrawn_connections_keep
			then
				log(
					string.format(
						"Redrawn Space Connections: Existing connection %s to %s kept due to exclusion flags",
						connection.from,
						connection.to
					)
				)

				if connection.redrawn_connections_rescale then
					log(
						string.format(
							"Redrawn Space Connections: Rescaling connection %s to %s",
							connection.from,
							connection.to
						)
					)
					connection.length = snap_length(connection_length(connection.from, connection.to))
				end

				connection.fixed = true

				fixed_edges[connection.from .. "-" .. connection.to] = connection
			else
				saved_asteroid_definitions[connection.from .. "-" .. connection.to] =
					connection.asteroid_spawn_definitions
				data.raw["space-connection"][name] = nil
			end
		end
	end
end

-- log("Fixed edges:")
-- log(serpent.block(fixed_edges))

local nodes = {}

local function calculate_virtual_coordinates(distance, orientation)
	local polar_x = distance
	local polar_y = orientation * 2 * math.pi

	local virtual_x = polar_x
	local virtual_y = polar_y * 20

	return virtual_x, virtual_y
end

local function add_node(name, loc)
	if loc.redrawn_connections_keep or name == "space-location-unknown" or loc.hidden then
		return
	end

	local angle = loc.orientation * 2 * math.pi
	local x = loc.distance * math.sin(angle)
	local y = -loc.distance * math.cos(angle)
	local polar_x = loc.distance
	local polar_y = angle

	local virtual_x, virtual_y = calculate_virtual_coordinates(loc.distance, loc.orientation)

	local node = {
		name = name,
		real_x = x,
		real_y = y,
		polar_x = polar_x,
		polar_y = polar_y,
	}

	if REAL_SPACE then
		node.virtual_x = x
		node.virtual_y = y
	else
		node.virtual_x = virtual_x
		node.virtual_y = virtual_y
	end

	table.insert(nodes, node)
end

for name, loc in pairs(data.raw["space-location"] or {}) do
	add_node(name, loc)
end

for name, loc in pairs(data.raw["planet"] or {}) do
	add_node(name, loc)
end

local function relative_angle_degrees(a, b)
	a = (a * 180 / math.pi) % 360
	b = (b * 180 / math.pi) % 360

	local diff = math.abs(a - b)
	if diff > 180 then
		diff = 360 - diff
	end
	return diff
end

local function point_in_circumcircle(p, tri)
	local ax = tri.p1.virtual_x
	local ay = tri.p1.virtual_y
	local bx = tri.p2.virtual_x
	local by = tri.p2.virtual_y
	local cx = tri.p3.virtual_x
	local cy = tri.p3.virtual_y

	local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
	if d == 0 then
		return false
	end

	local ax2 = ax * ax + ay * ay
	local bx2 = bx * bx + by * by
	local cx2 = cx * cx + cy * cy

	local center_x = (ax2 * (by - cy) + bx2 * (cy - ay) + cx2 * (ay - by)) / d
	local center_y = (ax2 * (cx - bx) + bx2 * (ax - cx) + cx2 * (bx - ax)) / d

	local dx = p.virtual_x - center_x
	local dy = p.virtual_y - center_y
	local dist2 = dx * dx + dy * dy

	local ra = ax - center_x
	local rb = ay - center_y
	local radius2 = ra * ra + rb * rb

	return dist2 <= radius2
end

local function calculate_triangulation(points)
	local min_x, max_x = math.huge, -math.huge
	local min_y, max_y = math.huge, -math.huge
	for _, p in ipairs(points) do
		if p.virtual_x < min_x then
			min_x = p.virtual_x
		end
		if p.virtual_x > max_x then
			max_x = p.virtual_x
		end
		if p.virtual_y < min_y then
			min_y = p.virtual_y
		end
		if p.virtual_y > max_y then
			max_y = p.virtual_y
		end
	end
	local dx = max_x - min_x
	local dy = max_y - min_y
	local dmax = math.max(dx, dy)
	local mid_x = (min_x + max_x) / 2
	local mid_y = (min_y + max_y) / 2

	local st_p1 = {
		name = "dt_super_1",
		virtual_x = mid_x - 2 * dmax,
		virtual_y = mid_y - dmax,
	}
	local st_p2 = {
		name = "dt_super_2",
		virtual_x = mid_x,
		virtual_y = mid_y + 2 * dmax,
	}
	local st_p3 = {
		name = "dt_super_3",
		virtual_x = mid_x + 2 * dmax,
		virtual_y = mid_y - dmax,
	}

	local triangles = {}
	table.insert(triangles, {
		p1 = st_p1,
		p2 = st_p2,
		p3 = st_p3,
	})

	for _, p in ipairs(points) do
		local badTriangles = {}
		for _, tri in ipairs(triangles) do
			if point_in_circumcircle(p, tri) then
				table.insert(badTriangles, tri)
			end
		end

		local edgeCount = {}
		local function addEdge(a, b)
			local key = a.name < b.name and (a.name .. "|" .. b.name) or (b.name .. "|" .. a.name)
			if edgeCount[key] then
				edgeCount[key].count = edgeCount[key].count + 1
			else
				edgeCount[key] = {
					edge = {
						from = a,
						to = b,
					},
					count = 1,
				}
			end
		end

		for _, tri in ipairs(badTriangles) do
			addEdge(tri.p1, tri.p2)
			addEdge(tri.p2, tri.p3)
			addEdge(tri.p3, tri.p1)
		end

		local polygonEdges = {}
		for _, info in pairs(edgeCount) do
			if info.count == 1 then
				table.insert(polygonEdges, info.edge)
			end
		end

		for i = #triangles, 1, -1 do
			for _, bt in ipairs(badTriangles) do
				if triangles[i] == bt then
					table.remove(triangles, i)
					break
				end
			end
		end

		for _, edge in ipairs(polygonEdges) do
			table.insert(triangles, {
				p1 = edge.from,
				p2 = edge.to,
				p3 = p,
			})
		end
	end

	local finalTriangles = {}
	for _, tri in ipairs(triangles) do
		if
			tri.p1.name:sub(1, 8) ~= "dt_super"
			and tri.p2.name:sub(1, 8) ~= "dt_super"
			and tri.p3.name:sub(1, 8) ~= "dt_super"
		then
			table.insert(finalTriangles, tri)
		end
	end

	return finalTriangles
end

local triangulation = calculate_triangulation(nodes)

local uniqueEdges = {}
for _, tri in ipairs(triangulation) do
	local function addEdge(nameA, nameB)
		local key = nameA < nameB and (nameA .. "|" .. nameB) or (nameB .. "|" .. nameA)
		uniqueEdges[key] = {
			from = nameA,
			to = nameB,
		}
	end
	addEdge(tri.p1.name, tri.p2.name)
	addEdge(tri.p2.name, tri.p3.name)
	addEdge(tri.p3.name, tri.p1.name)
end

local edges = {}
for _, edge in pairs(uniqueEdges) do
	table.insert(edges, edge)
end

-- log("Edges 0:")
-- log(serpent.block(edges))

for _, connection in pairs(fixed_edges) do
	-- Remove any existing edges that match our fixed edge
	for i = #edges, 1, -1 do
		local edge = edges[i]
		if
			(edge.from == connection.from and edge.to == connection.to)
			or (edge.from == connection.to and edge.to == connection.from)
		then
			table.remove(edges, i)
		end
	end

	table.insert(edges, connection)
end

-- log("Edges 1:")
-- log(serpent.block(edges))

local nodes_by_name = {}
for _, node in ipairs(nodes) do
	nodes_by_name[node.name] = node
end

local acceptedAngles = {}
for _, node in ipairs(nodes) do
	acceptedAngles[node.name] = {
		real = {},
		virtual = {},
	}
end

for _, connection in pairs(fixed_edges) do
	local nodeA = nodes_by_name[connection.from]
	local nodeB = nodes_by_name[connection.to]
	if nodeA and nodeB then
		local virtualAngleA = math.atan2(nodeB.virtual_y - nodeA.virtual_y, nodeB.virtual_x - nodeA.virtual_x)
		local realAngleA = math.atan2(nodeB.real_y - nodeA.real_y, nodeB.real_x - nodeA.real_x)
		local virtualAngleB = math.atan2(nodeA.virtual_y - nodeB.virtual_y, nodeA.virtual_x - nodeB.virtual_x)
		local realAngleB = math.atan2(nodeA.real_y - nodeB.real_y, nodeA.real_x - nodeB.real_x)
		table.insert(acceptedAngles[nodeA.name].virtual, virtualAngleA)
		table.insert(acceptedAngles[nodeA.name].real, realAngleA)
		table.insert(acceptedAngles[nodeB.name].virtual, virtualAngleB)
		table.insert(acceptedAngles[nodeB.name].real, realAngleB)
	end
end

-- log("Edges 2:")
-- log(serpent.block(edges))

for _, edge in ipairs(edges) do
	if not edge.fixed then
		log(string.format("Redrawn Space Connections: Setting length for %s to %s", edge.from, edge.to))
		edge.length = connection_length(edge.from, edge.to)
	end
end

-- log("Edges 3:")
-- log(serpent.block(edges))

table.sort(edges, function(a, b)
	return a.length < b.length
end)

local graph = {}
for _, edge in ipairs(edges) do
	graph[edge.from] = graph[edge.from] or {}
	graph[edge.to] = graph[edge.to] or {}
	local snapped_length = snap_length(edge.length)
	table.insert(graph[edge.from], {
		neighbor = edge.to,
		weight = snapped_length,
	})
	table.insert(graph[edge.to], {
		neighbor = edge.from,
		weight = snapped_length,
	})
end

local function find_shortest_path(source, target, exclude_edge)
	local distances = {}
	local visited = {}
	for node, _ in pairs(graph) do
		distances[node] = math.huge
	end
	distances[source] = 0

	while true do
		local current, currentDist = nil, math.huge
		for node, dist in pairs(distances) do
			if not visited[node] and dist < currentDist then
				current = node
				currentDist = dist
			end
		end
		if not current or current == target then
			break
		end
		visited[current] = true

		for _, edge in ipairs(graph[current]) do
			if
				not (current == exclude_edge.from and edge.neighbor == exclude_edge.to)
				and not (current == exclude_edge.to and edge.neighbor == exclude_edge.from)
			then
				local newDist = distances[current] + edge.weight
				if newDist < distances[edge.neighbor] then
					distances[edge.neighbor] = newDist
				end
			end
		end
	end
	return distances[target]
end

local triangle_filtered_edges = {}

local TRIANGLE_INEQUALITY_LENGTH_MULTIPLIER = 1

for _, edge in ipairs(edges) do
	if edge.fixed then
		table.insert(triangle_filtered_edges, edge)
	else
		local direct_length = edge.length
		local alternative_length = find_shortest_path(edge.from, edge.to, edge)

		if alternative_length > direct_length * TRIANGLE_INEQUALITY_LENGTH_MULTIPLIER then
			table.insert(triangle_filtered_edges, edge)
		else
			log(
				string.format(
					"Redrawn Space Connections: Connection %s to %s filtered out by triangle inequality. Direct length: %d, Alternative path length: %d",
					edge.from,
					edge.to,
					direct_length,
					alternative_length
				)
			)
		end
	end
end

edges = triangle_filtered_edges

-- local angleFilteredEdges = {}

-- table.sort(edges, function(a, b)
-- 	return a.length < b.length
-- end)

-- local REAL_ANGLE_CONFLICT_DEGREES = REAL_SPACE and 5 or 5
-- local VIRTUAL_ANGLE_CONFLICT_DEGREES = REAL_SPACE and 0 or 10

-- for _, edge in ipairs(edges) do
-- 	if edge.fixed then
-- 		table.insert(angleFilteredEdges, edge)
-- 		goto continue_edge
-- 	end

-- 	local nodeA = nodes_by_name[edge.from]
-- 	local nodeB = nodes_by_name[edge.to]
-- 	if not nodeA or not nodeB then
-- 		goto continue_edge
-- 	end

-- 	local virtualAngleA = math.atan2(nodeB.virtual_y - nodeA.virtual_y, nodeB.virtual_x - nodeA.virtual_x)
-- 	local virtualAngleB = math.atan2(nodeA.virtual_y - nodeB.virtual_y, nodeA.virtual_x - nodeB.virtual_x)

-- 	local realAngleA = math.atan2(nodeB.real_y - nodeA.real_y, nodeB.real_x - nodeA.real_x)
-- 	local realAngleB = math.atan2(nodeA.real_y - nodeB.real_y, nodeA.real_x - nodeB.real_x)

-- 	local conflict = false
-- 	local conflict_reason = ""

-- 	-- Check virtual angles at A
-- 	for _, existingAngle in ipairs(acceptedAngles[nodeA.name].virtual) do
-- 		local angle_diff = relative_angle_degrees(existingAngle, virtualAngleA)
-- 		if angle_diff < VIRTUAL_ANGLE_CONFLICT_DEGREES then
-- 			conflict = true
-- 			conflict_reason = string.format(
-- 				"Virtual angle A conflict: %.2f° vs existing %.2f° (diff: %.2f°) [length: %.2f]",
-- 				virtualAngleA * 180 / math.pi,
-- 				existingAngle * 180 / math.pi,
-- 				angle_diff,
-- 				edge.length
-- 			)
-- 			break
-- 		end
-- 	end

-- 	-- Check real angles at A
-- 	if not conflict then
-- 		for _, existingAngle in ipairs(acceptedAngles[nodeA.name].real) do
-- 			local angle_diff = relative_angle_degrees(existingAngle, realAngleA)
-- 			if angle_diff < REAL_ANGLE_CONFLICT_DEGREES then
-- 				conflict = true
-- 				conflict_reason = string.format(
-- 					"Real angle A conflict: %.2f° vs existing %.2f° (diff: %.2f°) [length: %.2f]",
-- 					realAngleA * 180 / math.pi,
-- 					existingAngle * 180 / math.pi,
-- 					angle_diff,
-- 					edge.length
-- 				)
-- 				break
-- 			end
-- 		end
-- 	end

-- 	-- Check virtual angles at B
-- 	if not conflict then
-- 		for _, existingAngle in ipairs(acceptedAngles[nodeB.name].virtual) do
-- 			local angle_diff = relative_angle_degrees(existingAngle, virtualAngleB)
-- 			if angle_diff < VIRTUAL_ANGLE_CONFLICT_DEGREES then
-- 				conflict = true
-- 				conflict_reason = string.format(
-- 					"Virtual angle B conflict: %.2f° vs existing %.2f° (diff: %.2f°) [length: %.2f]",
-- 					virtualAngleB * 180 / math.pi,
-- 					existingAngle * 180 / math.pi,
-- 					angle_diff,
-- 					edge.length
-- 				)
-- 				break
-- 			end
-- 		end
-- 	end

-- 	-- Check real angles at B
-- 	if not conflict then
-- 		for _, existingAngle in ipairs(acceptedAngles[nodeB.name].real) do
-- 			local angle_diff = relative_angle_degrees(existingAngle, realAngleB)
-- 			if angle_diff < REAL_ANGLE_CONFLICT_DEGREES then
-- 				conflict = true
-- 				conflict_reason = string.format(
-- 					"Real angle B conflict: %.2f° vs existing %.2f° (diff: %.2f°) [length: %.2f]",
-- 					realAngleB * 180 / math.pi,
-- 					existingAngle * 180 / math.pi,
-- 					angle_diff,
-- 					edge.length
-- 				)
-- 				break
-- 			end
-- 		end
-- 	end

-- 	if conflict then
-- 		log(
-- 			string.format(
-- 				"Redrawn Space Connections: Connection %s to %s filtered out due to %s",
-- 				edge.from,
-- 				edge.to,
-- 				conflict_reason
-- 			)
-- 		)
-- 	else
-- 		table.insert(angleFilteredEdges, edge)
-- 		table.insert(acceptedAngles[nodeA.name].virtual, virtualAngleA)
-- 		table.insert(acceptedAngles[nodeA.name].real, realAngleA)
-- 		table.insert(acceptedAngles[nodeB.name].virtual, virtualAngleB)
-- 		table.insert(acceptedAngles[nodeB.name].real, realAngleB)
-- 	end

-- 	::continue_edge::
-- end

-- edges = angleFilteredEdges

local function get_asteroid_definitions(from, to)
	if saved_asteroid_definitions[from .. "-" .. to] then
		return saved_asteroid_definitions[from .. "-" .. to]
	end

	if saved_asteroid_definitions[to .. "-" .. from] then
		return saved_asteroid_definitions[to .. "-" .. from], true
	end

	if to == "solar-system-edge" then
		return asteroid_util.spawn_definitions(asteroid_util.aquilo_solar_system_edge), true
	elseif from == "solar-system-edge" then
		return asteroid_util.spawn_definitions(asteroid_util.aquilo_solar_system_edge), false
	elseif to == "aquilo" or to == "maraxsis" then
		return asteroid_util.spawn_definitions(asteroid_util.gleba_aquilo), true
	elseif from == "aquilo" or from == "maraxsis" then
		return asteroid_util.spawn_definitions(asteroid_util.gleba_aquilo), false
	elseif from == "nauvis" then
		return asteroid_util.spawn_definitions(asteroid_util.nauvis_fulgora), false
	elseif to == "nauvis" then
		return asteroid_util.spawn_definitions(asteroid_util.nauvis_fulgora), true
	end

	return asteroid_util.spawn_definitions(asteroid_util.gleba_fulgora), false
end

local connections_to_add = {}

local new_edges = {}
for _, edge in ipairs(edges) do
	if not edge.fixed then
		table.insert(new_edges, edge)
	end
end

for _, edge in ipairs(new_edges) do
	local from = edge.from
	local to = edge.to

	local definitions, should_flip = get_asteroid_definitions(from, to)

	if should_flip then
		from, to = to, from
	end

	local from_prototype = data.raw.planet[from] or data.raw["space-location"][from]
	local to_prototype = data.raw.planet[to] or data.raw["space-location"][to]

	local connection = {
		type = "space-connection",
		name = from .. "-" .. to,
		subgroup = "planet-connections",
		from = from,
		to = to,
		order = from .. "-" .. to,
		length = snap_length(edge.length),
		asteroid_spawn_definitions = definitions,
	}

	if from_prototype.icon and to_prototype.icon then
		connection.icons = {
			{
				icon = "__space-age__/graphics/icons/planet-route.png",
				icon_size = 64,
			},
			{
				icon = from_prototype.icon,
				icon_size = from_prototype.icon_size or 64,
				scale = 0.333 * (64 / (from_prototype.icon_size or 64)),
				shift = { -6, -6 },
			},
			{
				icon = to_prototype.icon,
				icon_size = to_prototype.icon_size or 64,
				scale = 0.333 * (64 / (to_prototype.icon_size or 64)),
				shift = { 6, 6 },
			},
		}
	else
		connection.icon = "__space-age__/graphics/icons/planet-route.png"
		connection.icon_size = 64
	end

	table.insert(connections_to_add, connection)
end

data:extend(connections_to_add)

--== DEBUG ==--

-- for _, connection in pairs(data.raw["space-connection"] or {}) do
-- 	-- Un-snap lengths
-- 	connection.length = connection_length(connection.from, connection.to)
-- end

-- local function to_polar(x, y)
-- 	local distance = math.sqrt(x * x + y * y)
-- 	local orientation = math.atan2(y, x) / (2 * math.pi)
-- 	if orientation < 0 then
-- 		orientation = orientation + 1
-- 	end
-- 	return distance, orientation
-- end
-- for _, prototype_type in pairs({ "space-location", "planet" }) do
-- 	for _, prototype in pairs(data.raw[prototype_type] or {}) do
-- 		local virtual_x, virtual_y = calculate_virtual_coordinates(prototype.distance, prototype.orientation)

-- 		local new_distance, new_orientation = to_polar(virtual_x, virtual_y)

-- 		prototype.distance = new_distance
-- 		prototype.orientation = new_orientation
-- 	end
-- end
-- data.raw["utility-sprites"]["default"].starmap_star = {
-- 	type = "sprite",
-- 	filename = "__core__/graphics/icons/starmap-star.png",
-- 	priority = "extra-high-no-scale",
-- 	size = 512,
-- 	flags = { "gui-icon" },
-- 	scale = 0.5,
-- }
