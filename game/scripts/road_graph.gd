extends RefCounted
## Drivable road network as a graph for routing (the GPS line on the map).
## Every polyline vertex is a node; consecutive vertices are edges; roads
## that share a vertex (within SNAP) join there.

const SNAP := 1.5

var _nodes: PackedVector2Array = PackedVector2Array()
var _adj: Array = []          # node index -> Array of [neighbour, length]
var _edges: Array = []        # [a, b] node pairs, for nearest-segment lookup
var _keys: Dictionary = {}    # Vector2i -> node index


func build(roads: Array[Dictionary], drivable: Array) -> void:
	for r in roads:
		if not (r["highway"] in drivable) or r["service"] == "driveway":
			continue
		var pts: PackedVector2Array = r["pts"]
		var prev := -1
		for p in pts:
			var idx := _node_for(p)
			if prev >= 0 and prev != idx:
				_link(prev, idx)
			prev = idx


func size() -> int:
	return _nodes.size()


func _node_for(p: Vector2) -> int:
	var key := Vector2i(roundi(p.x / SNAP), roundi(p.y / SNAP))
	if _keys.has(key):
		return _keys[key]
	_nodes.append(p)
	_adj.append([])
	_keys[key] = _nodes.size() - 1
	return _nodes.size() - 1


func _link(a: int, b: int) -> void:
	var d := _nodes[a].distance_to(_nodes[b])
	_adj[a].append([b, d])
	_adj[b].append([a, d])
	_edges.append([a, b])


## Nearest point on the network to `p`: [point, edge index, t along edge].
func nearest(p: Vector2) -> Array:
	var best := INF
	var out := [p, -1, 0.0]
	for i in _edges.size():
		var a := _nodes[_edges[i][0]]
		var b := _nodes[_edges[i][1]]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_squared_to(q)
		if d < best:
			best = d
			var len := a.distance_to(b)
			out = [q, i, (q.distance_to(a) / len) if len > 0.0 else 0.0]
	return out


## Shortest drive from `from` to `to` as a polyline (empty if unreachable).
func route(from: Vector2, to: Vector2) -> PackedVector2Array:
	if _edges.is_empty():
		return PackedVector2Array()
	var s := nearest(from)
	var g := nearest(to)
	if s[1] < 0 or g[1] < 0:
		return PackedVector2Array()
	var n := _nodes.size()
	# Virtual start/goal nodes spliced into their segments.
	var start := n
	var goal := n + 1
	var dist := PackedFloat64Array()
	dist.resize(n + 2)
	dist.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(n + 2)
	prev.fill(-1)
	var extra := {}  # node -> Array of [neighbour, length] (virtual links)
	var sa: int = _edges[s[1]][0]
	var sb: int = _edges[s[1]][1]
	var ga: int = _edges[g[1]][0]
	var gb: int = _edges[g[1]][1]
	var sp: Vector2 = s[0]
	var gp: Vector2 = g[0]
	extra[start] = [[sa, sp.distance_to(_nodes[sa])], [sb, sp.distance_to(_nodes[sb])]]
	extra[ga] = [[goal, gp.distance_to(_nodes[ga])]]
	extra[gb] = extra.get(gb, []) + [[goal, gp.distance_to(_nodes[gb])]]
	if s[1] == g[1]:
		extra[start].append([goal, sp.distance_to(gp)])
	dist[start] = 0.0
	var open: Array = [[0.0, start]]
	var done := {}
	while not open.is_empty():
		# Smallest tentative distance (linear scan; networks here are small).
		var bi := 0
		for i in range(1, open.size()):
			if open[i][0] < open[bi][0]:
				bi = i
		var cur: Array = open[bi]
		open.remove_at(bi)
		var u: int = cur[1]
		if done.has(u):
			continue
		done[u] = true
		if u == goal:
			break
		var links: Array = []
		if u < n:
			links = _adj[u].duplicate()
		if extra.has(u):
			links += extra[u]
		for l in links:
			var v: int = l[0]
			var nd: float = dist[u] + l[1]
			if nd < dist[v]:
				dist[v] = nd
				prev[v] = u
				open.append([nd, v])
	if dist[goal] == INF:
		return PackedVector2Array()
	var path := PackedVector2Array()
	var u := goal
	while u >= 0:
		path.append(gp if u == goal else (sp if u == start else _nodes[u]))
		u = prev[u]
	path.reverse()
	return path


func length_of(path: PackedVector2Array) -> float:
	var t := 0.0
	for i in path.size() - 1:
		t += path[i].distance_to(path[i + 1])
	return t
