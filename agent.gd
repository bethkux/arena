extends Node2D

# References
@onready var ship = get_parent()
@onready var arena = get_parent().get_parent()
@onready var debug_path = ship.get_node('../debug_path')

# State
var ticks = 0
var spin_dir = 0
var apply_thrust = false
var line_visual
var level_shot_trigger = 0
var debug_mode = false


func _ready() -> void:
	line_visual = Line2D.new()
	add_child(line_visual)


# -------------------------------------------------------------------------
# --- Utility Methods ------------------------------------------------------
# -------------------------------------------------------------------------

## Returns the index of the polygon containing a given position.
func get_polygon_index(pos:Vector2, polygons:Array[PackedVector2Array]) -> int:
	var idx := 0
	for poly in polygons:
		if Geometry2D.is_point_in_polygon(pos, poly):
			return idx
		idx += 1
	return -1


## Checks if a point is clear of walls based on the ship radius.
func is_point_clear_of_walls(point:Vector2, walls:Array[PackedVector2Array]) -> bool:
	for wall in walls:
		if Util.distance_segment_to_polygon(point, ship.position, wall) <= ship.RADIUS:
			return false
	return true


## Finds the midpoint of the shared edge between two polygons.
func get_shared_edge_midpoint(poly_a:PackedVector2Array, poly_b:PackedVector2Array, _unused) -> Vector2:
	var first:Vector2
	var second:Vector2
	for a in poly_a:
		for b in poly_b:
			if a == b:
				if not first:
					first = a
				else:
					second = a
	return (first + second) / 2


# -------------------------------------------------------------------------
# --- Sub-Methods Supporting Action() -------------------------------------
# -------------------------------------------------------------------------


## Draws a line showing the velocity vector.
func draw_debug_velocity():
	if debug_mode:
		line_visual.clear_points()
		line_visual.add_point(Vector2.ZERO)
		line_visual.add_point(ship.velocity)
		line_visual.rotation = -ship.rotation


## Evaluates gem positions and returns info + potential immediate target.
func evaluate_gem_positions(gems, polygons, walls):
	var gem_polygon_ids = []
	var gem_positions = []
	var target := Vector2.ZERO
	var closest_dist = ship.position.distance_to(gems[0])

	for gem in gems:
		if gem.distance_to(ship.position) < closest_dist:
			if is_point_clear_of_walls(gem, walls):
				target = gem

		var gem_poly_id = get_polygon_index(gem, polygons)

		gem_polygon_ids.append(gem_poly_id)
		gem_positions.append(gem)

	return [gem_polygon_ids, gem_positions, target]


## Search across connected polygons to find a reachable gem.
func find_path_to_gem(ship_polygon, polygons, neighbors, walls, gem_polygon_ids, gem_positions):
	var open_set = [ship_polygon]
	var came_from = {} 
	var g_score = {}
	var f_score = {}

	for i in range(polygons.size()):
		g_score[i] = INF
		f_score[i] = INF

	g_score[ship_polygon] = 0
	f_score[ship_polygon] = 0 

	# Precompute polygon centers for heuristic
	var centers = []
	for poly in polygons:
		var sum = Vector2.ZERO
		for pt in poly:
			sum += pt
		centers.append(sum / poly.size())

	while open_set.size() > 0:
		# Find polygon in open_set with lowest f_score
		var current = open_set[0]
		var lowest_f = f_score[current]
		for poly_id in open_set:
			if f_score[poly_id] < lowest_f:
				current = poly_id
				lowest_f = f_score[poly_id]

		open_set.erase(current)

		# Check if current contains a gem
		var gem_index = gem_polygon_ids.find(current)
		if gem_index != -1:
			# Reconstruct path
			var path = [ship.position]
			var p = current
			var last_point = ship.position
			while came_from.has(p):
				var mid = get_shared_edge_midpoint(polygons[came_from[p]], polygons[p], last_point)
				path.insert(1, mid)
				last_point = mid
				p = came_from[p]
			return get_best_path_target(path, gem_positions[gem_index], walls)

		for neighbor in neighbors[current]:
			var tentative_g = g_score[current] + (centers[current] - centers[neighbor]).length()
			if tentative_g < g_score[neighbor]:
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g

				var h = INF
				for gem_pos in gem_positions:
					h = min(h, (centers[neighbor] - gem_pos).length())
				f_score[neighbor] = g_score[neighbor] + h

				if neighbor not in open_set:
					open_set.append(neighbor)
	return Vector2.ZERO


## Chooses the clearest reachable point along the found polygon path.
func get_best_path_target(path, gem_position, walls):
	path.append(gem_position)
	var last_clear_idx := 0

	for i in range(path.size() - 1, 0, -1):
		if is_point_clear_of_walls(path[i], walls):
			last_clear_idx = i
			add_debug_path_segments(path, i)
			return path[i]

	# Fallback: Bezier-based smoothing
	if path.size() > 3 and last_clear_idx == 1:
		var bez = path[0].bezier_interpolate(path[1], path[2], path[3], 0.3)
		if is_point_clear_of_walls(bez, walls):
			debug_path.set_point_position(0, bez)
			return bez

	return Vector2.ZERO


## Draws the chosen path into the debug line.
func add_debug_path_segments(path, from_idx):
	for pt in path.slice(from_idx):
		debug_path.add_point(pt)


## Determines whether the ship should fire.
func evaluate_shoot_decision():
	var shoot := false
	var time_left = arena.time_left
	var current_level = arena.level
	#var score = arena.score

	if (level_shot_trigger != current_level and current_level > 2 and time_left < 15):
	#(score < 300 and time_left < 20):
		shoot = true
		level_shot_trigger = current_level
	return shoot


## Updates spin direction and thrust based on ship–target angle and velocity.
func update_movement_controls(target, shoot):
	var aim_angle = ship.get_angle_to(target)
	var vel = ship.velocity
	apply_thrust = false

	if vel.length() > 50 and abs(vel.angle_to(target - ship.position)) > PI / 4:
		spin_dir = -1 if ((-vel).angle() - ship.rotation < 0) else 1
		if abs((-vel).angle() - ship.rotation) < 0.4:
			apply_thrust = true
	else:
		if abs(vel.length() * (vel.normalized().dot((target - ship.position).normalized()))) < 120:
			apply_thrust = true
		spin_dir = -1 if aim_angle < 0 else 1

	if shoot and ship.lasers == 0:
		apply_thrust = false


# -------------------------------------------------------------------------
# --- Main AI Action Loop -------------------------------------------------
# -------------------------------------------------------------------------

func action(walls, gems, polygons, neighbors):
	draw_debug_velocity()
	debug_path.clear_points()
	debug_path.add_point(ship.position)

	# --- Analyze gem locations ---
	var gem_data = evaluate_gem_positions(gems, polygons, walls)
	var gem_polygon_ids = gem_data[0]
	var gem_positions = gem_data[1]
	var target = gem_data[2]

	if target != Vector2.ZERO:
		debug_path.add_point(target)
	else:
		target = find_path_to_gem(get_polygon_index(ship.position, polygons), polygons, neighbors, walls, gem_polygon_ids, gem_positions)
		if target == Vector2.ZERO:
			debug_path.add_point(target)
			target = gems[0]

	var shoot = evaluate_shoot_decision()
	update_movement_controls(target, shoot)
	ticks += 1
	
	return [spin_dir, apply_thrust, shoot]


# -------------------------------------------------------------------------
# --- Notifications -------------------------------------------------------
# -------------------------------------------------------------------------

func bounce():
	return

func gem_collected():
	return
