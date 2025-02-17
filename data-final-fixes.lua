local Delaunay = require("delaunay")
local asteroid_util = require("__space-age__.prototypes.planet.asteroid-spawn-definitions")

local SCALE_FACTOR = 1250
local REAL_SPACE = settings.startup["redrawn-space-connections-real-space-triangulation"].value

local function connection_length(from_name, to_name)
	local from_planet = data.raw.planet[from_name] or data.raw["space-location"][from_name]
	local to_planet = data.raw.planet[to_name] or data.raw["space-location"][to_name]

	if not from_planet or not to_planet then
		log(string.format("Redrawn Space Connections: Connection %s to %s has invalid planets", from_name, to_name))
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

	local multiplier = 1

	if from_planet.redrawn_connections_length_multiplier then
		multiplier = math.max(multiplier, from_planet.redrawn_connections_length_multiplier)
	end
	if to_planet.redrawn_connections_length_multiplier then
		multiplier = math.max(multiplier, to_planet.redrawn_connections_length_multiplier)
	end

	return curved_distance * SCALE_FACTOR * multiplier
end

local function snapped_length(length)
	return math.ceil(length / 1000) * 1000
end

local fixed_edges = {}
local saved_asteroid_definitions = {}

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
				connection.length = snapped_length(connection_length(connection.from, connection.to))
			end

			connection.fixed = true

			fixed_edges[connection.from .. "-" .. connection.to] = connection
		else
			saved_asteroid_definitions[connection.from .. "-" .. connection.to] = connection.asteroid_spawn_definitions
			data.raw["space-connection"][name] = nil
		end
	end
end

local nodes = {}
local nodes_by_name = {}

local function calculate_virtual_coordinates(distance, orientation)
	local polar_x = distance
	local polar_y = orientation * 2 * math.pi

	local virtual_x = polar_x
	local virtual_y = polar_y * 20

	return virtual_x, virtual_y
end

local function add_node(name, loc)
	if loc.redrawn_connections_keep or name == "space-location-unknown" then
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
	nodes_by_name[name] = node
end

for _, type in pairs({ "space-location", "planet" }) do
	for name, loc in pairs(data.raw[type] or {}) do
		add_node(name, loc)
	end
end

local triangulation_points = {}
local points_to_names = {}

for _, node in ipairs(nodes) do
	local vertex = Delaunay.vertex(node.virtual_x, node.virtual_y)
	local key = string.format("%.10f,%.10f", node.virtual_x, node.virtual_y)
	points_to_names[key] = node.name
	table.insert(triangulation_points, vertex)
end

local constraint_lines = {}
for _, connection in pairs(fixed_edges) do
	local from_node = nodes_by_name[connection.from]
	local to_node = nodes_by_name[connection.to]
	if from_node and to_node then
		local line = {
			Delaunay.vertex(from_node.virtual_x, from_node.virtual_y),
			Delaunay.vertex(to_node.virtual_x, to_node.virtual_y),
		}
		table.insert(constraint_lines, line)
	end
end

local triangulation
if #constraint_lines > 0 then
	triangulation = Delaunay.constrainedTriangulation(triangulation_points, constraint_lines)
else
	triangulation = Delaunay.triangulate(triangulation_points)
end

for _, tri in ipairs(triangulation) do
	local function get_name(vertex)
		local key = string.format("%.10f,%.10f", vertex.position[1], vertex.position[2])
		return points_to_names[key]
	end

	tri.p1 = tri.v1
	tri.p2 = tri.v2
	tri.p3 = tri.v3

	tri.p1.name = get_name(tri.v1)
	tri.p2.name = get_name(tri.v2)
	tri.p3.name = get_name(tri.v3)
end

local edges = {}

local function ensure_edge(nameA, nameB)
	for _, edge in ipairs(edges) do
		if (edge.from == nameA and edge.to == nameB) or (edge.from == nameB and edge.to == nameA) then
			return
		end
	end

	table.insert(edges, {
		from = nameA,
		to = nameB,
		length = connection_length(nameA, nameB),
	})
end

for _, tri in ipairs(triangulation) do
	ensure_edge(tri.p1.name, tri.p2.name)
	ensure_edge(tri.p2.name, tri.p3.name)
	ensure_edge(tri.p3.name, tri.p1.name)
end

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
	if not edge.fixed then
		edge.length = connection_length(edge.from, edge.to)
	end
end

table.sort(edges, function(a, b)
	return a.length < b.length
end)

local graph = {}
for _, edge in ipairs(edges) do
	graph[edge.from] = graph[edge.from] or {}
	graph[edge.to] = graph[edge.to] or {}
	local length = snapped_length(edge.length)
	table.insert(graph[edge.from], {
		neighbor = edge.to,
		weight = length,
	})
	table.insert(graph[edge.to], {
		neighbor = edge.from,
		weight = length,
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

local angleFilteredEdges = {}

table.sort(edges, function(a, b)
	return a.length < b.length
end)

local function relative_angle_degrees(a, b)
	a = (a * 180 / math.pi) % 360
	b = (b * 180 / math.pi) % 360

	local diff = math.abs(a - b)
	if diff > 180 then
		diff = 360 - diff
	end
	return diff
end

local REAL_ANGLE_CONFLICT_DEGREES = REAL_SPACE and 5 or 5
local VIRTUAL_ANGLE_CONFLICT_DEGREES = REAL_SPACE and 0 or 10

for _, edge in ipairs(edges) do
	if edge.fixed then
		table.insert(angleFilteredEdges, edge)
		goto continue_edge
	end

	local nodeA = nodes_by_name[edge.from]
	local nodeB = nodes_by_name[edge.to]
	if not nodeA or not nodeB then
		goto continue_edge
	end

	local virtualAngleA = math.atan2(nodeB.virtual_y - nodeA.virtual_y, nodeB.virtual_x - nodeA.virtual_x)
	local virtualAngleB = math.atan2(nodeA.virtual_y - nodeB.virtual_y, nodeA.virtual_x - nodeB.virtual_x)

	local realAngleA = math.atan2(nodeB.real_y - nodeA.real_y, nodeB.real_x - nodeA.real_x)
	local realAngleB = math.atan2(nodeA.real_y - nodeB.real_y, nodeA.real_x - nodeB.real_x)

	local conflict = false
	local conflict_reason = ""

	-- Check virtual angles at A
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

	-- Check real angles at A
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

	-- Check virtual angles at B
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

	-- Check real angles at B
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
				edge.from,
				edge.to,
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
		length = snapped_length(edge.length),
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

if #connections_to_add > 0 then
	data:extend(connections_to_add)
end

-- DEBUG:
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
