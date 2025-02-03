local asteroid_util = require("__space-age__.prototypes.planet.asteroid-spawn-definitions")

local saved_asteroid_definitions = {}

local fixed_edges = {}
if data.raw["space-connection"] then
	for name, connection in pairs(data.raw["space-connection"]) do
		local from_loc = data.raw["planet"][connection.from] or data.raw["space-location"][connection.from]
		local to_loc = data.raw["planet"][connection.to] or data.raw["space-location"][connection.to]

		if from_loc and to_loc and (from_loc.redrawn_connections_exclude or to_loc.redrawn_connections_exclude) then
			fixed_edges[connection.from .. "-" .. connection.to] = connection
		else
			saved_asteroid_definitions[connection.from .. "-" .. connection.to] = connection.asteroid_spawn_definitions
			data.raw["space-connection"][name] = nil
		end
	end
end

local nodes = {}

local SCALE_FACTOR = 1250

if mods["Tiered-Solar-System"] then
	SCALE_FACTOR = 1000
end

local function connection_length(from_name, to_name)
	local from_planet = data.raw.planet[from_name] or data.raw["space-location"][from_name]
	local to_planet = data.raw.planet[to_name] or data.raw["space-location"][to_name]

	if not from_planet or not to_planet then
		return nil
	end

	if from_planet.orientation == to_planet.orientation and from_planet.distance == to_planet.distance then
		return 1 -- because 0 breaks the game
	end

	local angle1 = from_planet.orientation * 2 * math.pi
	local angle2 = to_planet.orientation * 2 * math.pi

	local r1 = from_planet.distance or 0
	local r2 = to_planet.distance or 0

	local angle_diff = math.abs(angle2 - angle1)

	local straight_distance = math.sqrt(r1 * r1 + r2 * r2 - 2 * r1 * r2 * math.cos(angle_diff))

	-- local curvature_factor = 1.0 + (math.pi / 2 - 1.0) * (angle_diff / math.pi)
	local curvature_factor = 1.0 + (math.pi / 2 - 1.0) * (angle_diff / math.pi) / 2 -- This factor is less strictly accurate, but it respects 'triangle inequalities' better

	local curved_distance = straight_distance * curvature_factor

	if from_planet.redrawn_connections_length_multiplier then
		curved_distance = curved_distance * from_planet.redrawn_connections_length_multiplier
	end

	if to_planet.redrawn_connections_length_multiplier then
		curved_distance = curved_distance * to_planet.redrawn_connections_length_multiplier
	end

	return curved_distance * SCALE_FACTOR
end

local function connection_length_snapped(from_name, to_name)
	local distance = connection_length(from_name, to_name)

	return math.ceil(distance / 1000) * 1000
end

local function add_node(name, loc)
	if loc.redrawn_connections_exclude or name == "space-location-unknown" then
		return
	end

	local angle = loc.orientation * 2 * math.pi

	local x = loc.distance * math.sin(angle)
	local y = -loc.distance * math.cos(angle)

	local polar_x = loc.distance
	local polar_y = angle

	local virtual_x = polar_x
	local virtual_y = polar_y * 20

	table.insert(nodes, {
		name = name,
		real_x = x,
		real_y = y,
		polar_x = polar_x,
		polar_y = polar_y,
		virtual_x = virtual_x,
		virtual_y = virtual_y,
	})
end

for name, loc in pairs(data.raw["space-location"] or {}) do
	add_node(name, loc)
end

for name, loc in pairs(data.raw["planet"] or {}) do
	add_node(name, loc)
end

-- log all the nodes:
for _, node in ipairs(nodes) do
	log(
		string.format(
			"Node: %s, Real X: %.2f, Real Y: %.2f, Virtual X: %.2f, Virtual Y: %.2f",
			node.name,
			node.real_x,
			node.real_y,
			node.virtual_x,
			node.virtual_y
		)
	)
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
						a = a,
						b = b,
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
				p1 = edge.a,
				p2 = edge.b,
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
			a = nameA,
			b = nameB,
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

for _, edge in ipairs(edges) do
	edge.length = connection_length(edge.a, edge.b)
end

table.sort(edges, function(a, b)
	return a.length < b.length
end)

local angleFilteredEdges = {}

local REAL_ANGLE_CONFLICT_DEGREES = 5
local VIRTUAL_ANGLE_CONFLICT_DEGREES = 10

for _, edge in ipairs(edges) do
	local nodeA = nodes_by_name[edge.a]
	local nodeB = nodes_by_name[edge.b]
	if not nodeA or not nodeB then
		goto continue_edge
	end

	local virtualAngleA = math.atan2(nodeB.virtual_y - nodeA.virtual_y, nodeB.virtual_x - nodeA.virtual_x)
	local virtualAngleB = math.atan2(nodeA.virtual_y - nodeB.virtual_y, nodeA.virtual_x - nodeB.virtual_x)

	local realAngleA = math.atan2(nodeB.real_y - nodeA.real_y, nodeB.real_x - nodeA.real_x)
	local realAngleB = math.atan2(nodeA.real_y - nodeB.real_y, nodeA.real_x - nodeB.real_x)

	local conflict = false
	local conflict_reason = ""

	-- Check virtual angle A
	for _, existingAngle in ipairs(acceptedAngles[nodeA.name].virtual) do
		local angle_diff = relative_angle_degrees(existingAngle, virtualAngleA)
		if angle_diff < VIRTUAL_ANGLE_CONFLICT_DEGREES then
			conflict = true
			conflict_reason = string.format(
				"Virtual angle A conflict: %.2f° vs existing %.2f° (diff: %.2f°)",
				virtualAngleA * 180 / math.pi,
				existingAngle * 180 / math.pi,
				angle_diff
			)
			break
		end
	end

	-- Check real angle A
	if not conflict then
		for _, existingAngle in ipairs(acceptedAngles[nodeA.name].real) do
			local angle_diff = relative_angle_degrees(existingAngle, realAngleA)
			if angle_diff < REAL_ANGLE_CONFLICT_DEGREES then
				conflict = true
				conflict_reason = string.format(
					"Real angle A conflict: %.2f° vs existing %.2f° (diff: %.2f°)",
					realAngleA * 180 / math.pi,
					existingAngle * 180 / math.pi,
					angle_diff
				)
				break
			end
		end
	end

	-- Check virtual angle B
	if not conflict then
		for _, existingAngle in ipairs(acceptedAngles[nodeB.name].virtual) do
			local angle_diff = relative_angle_degrees(existingAngle, virtualAngleB)
			if angle_diff < VIRTUAL_ANGLE_CONFLICT_DEGREES then
				conflict = true
				conflict_reason = string.format(
					"Virtual angle B conflict: %.2f° vs existing %.2f° (diff: %.2f°)",
					virtualAngleB * 180 / math.pi,
					existingAngle * 180 / math.pi,
					angle_diff
				)
				break
			end
		end
	end

	-- Check real angle B
	if not conflict then
		for _, existingAngle in ipairs(acceptedAngles[nodeB.name].real) do
			local angle_diff = relative_angle_degrees(existingAngle, realAngleB)
			if angle_diff < REAL_ANGLE_CONFLICT_DEGREES then
				conflict = true
				conflict_reason = string.format(
					"Real angle B conflict: %.2f° vs existing %.2f° (diff: %.2f°)",
					realAngleB * 180 / math.pi,
					existingAngle * 180 / math.pi,
					angle_diff
				)
				break
			end
		end
	end

	if conflict then
		log(
			string.format(
				"Redrawn Space Connections: Connection %s to %s filtered out due to %s",
				edge.a,
				edge.b,
				conflict_reason
			)
		)
	else
		table.insert(angleFilteredEdges, edge)
		table.insert(acceptedAngles[nodeA.name].virtual, virtualAngleA)
		table.insert(acceptedAngles[nodeA.name].real, realAngleA)
		table.insert(acceptedAngles[nodeB.name].virtual, virtualAngleB)
		table.insert(acceptedAngles[nodeB.name].real, realAngleB)
	end

	::continue_edge::
end

edges = angleFilteredEdges

local graph = {}
for _, edge in ipairs(edges) do
	graph[edge.a] = graph[edge.a] or {}
	graph[edge.b] = graph[edge.b] or {}
	local snapped_length = connection_length_snapped(edge.a, edge.b)
	table.insert(graph[edge.a], { neighbor = edge.b, weight = snapped_length })
	table.insert(graph[edge.b], { neighbor = edge.a, weight = snapped_length })
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
				not (current == exclude_edge.a and edge.neighbor == exclude_edge.b)
				and not (current == exclude_edge.b and edge.neighbor == exclude_edge.a)
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

local TRIANGLE_INEQUALITY_LENGTH_MULTIPLIER = 1.1

for _, edge in ipairs(edges) do
	local direct_length = connection_length_snapped(edge.a, edge.b)
	local alternative_length = find_shortest_path(edge.a, edge.b, edge)

	if alternative_length > direct_length * TRIANGLE_INEQUALITY_LENGTH_MULTIPLIER then
		table.insert(triangle_filtered_edges, edge)
	else
		log(
			string.format(
				"Redrawn Space Connections: Connection %s to %s filtered out by triangle inequality. Direct length: %d, Alternative path length: %d",
				edge.a,
				edge.b,
				direct_length,
				alternative_length
			)
		)
	end
end

edges = triangle_filtered_edges

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
	elseif to == "aquilo" then
		return asteroid_util.spawn_definitions(asteroid_util.gleba_aquilo), true
	elseif from == "aquilo" then
		return asteroid_util.spawn_definitions(asteroid_util.gleba_aquilo), false
	elseif from == "nauvis" then
		return asteroid_util.spawn_definitions(asteroid_util.nauvis_fulgora), false
	elseif to == "nauvis" then
		return asteroid_util.spawn_definitions(asteroid_util.nauvis_fulgora), true
	end

	return asteroid_util.spawn_definitions(asteroid_util.gleba_fulgora), false
end

local connections_to_add = {}

for _, edge in ipairs(edges) do
	local from = edge.a
	local to = edge.b

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
		length = connection_length_snapped(from, to),
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
