class_name PotatoC
# PotatoC scripting language interpreter.
# Direct port of source/cpp/potatoc.h + potatoc.cpp to GDScript.
# Author: Alan Fischer, Date: 12/17/00 (original C++)

enum Type {
	NONE, VARREF, ASSIGN, ADD, SUBTRACT, MULTIPLY, DIVIDE, OR, AND,
	IF, BEGIN, VARCREATE, EQUALS, FUNCTION, STRING, WHILE,
	NOTEQUAL, LESSTHAN, GREATERTHAN,
}

# Delimiter strings and their split priority. _next_delim picks the highest-valued
# delimiter present, and that becomes the expression's top-level split — a HIGHER
# value means a LOOSER-binding operator.
#
# Values are the C++ delimvalue[] doubled, with one deliberate correction: there,
# `<`/`>` shared 5 with `&&`/`||`, so `x<-400&&y>-1200` parsed as `x < ((-400) && (y >
# -1200))` — ww_golem's spawn-group check is written exactly that way and silently
# broke (blue spawned in its forward house from map load). Comparisons now sit at 9,
# between arithmetic (8) and the logical operators (10); everything else matches the C++.
#
# Two divergences from C remain, inherited and unexercised by any shipped map: `||`
# still ties with `&&` (`a&&b||c` groups as `a&&(b||c)`), and `==`/`!=` still bind
# tighter than `+`/`-` (`a+b==c` groups as `a+(b==c)`).
const DELIMS := ["\\", ";", ":", "==", "+", "-", "*", "/", "#", "||", "&&", "!=", ",", "'", "<", ">"]
const DELIM_VALUES := [0, 2, 18, 6, 8, 8, 8, 8, 20, 10, 10, 6, 14, 12, 9, 9]

static var global_vars: Dictionary = {}

var function_handler: Callable
var _main_app: App = null


class App:
	var type: int = Type.NONE
	var str_val: String = ""
	var app1: App = null
	var app2: App = null


static func parse_globals(globals: String) -> void:
	var parts := globals.split(";", false)
	for part in parts:
		var name := part.strip_edges()
		if name.is_empty():
			continue
		if not global_vars.has(name):
			global_vars[name] = 0


func parse_code(code: String) -> void:
	code = clean(code)
	_main_app = App.new()
	_parse(code, _main_app)


func execute() -> int:
	var local_vars := {}
	return _execute(_main_app, local_vars)


func _parse(chunk: String, app: App) -> String:
	if chunk.is_empty():
		return chunk

	# String literal: 'text'
	if chunk.begins_with("'"):
		var end_idx := chunk.find("'", 1)
		app.type = Type.STRING
		app.str_val = chunk.substr(1, end_idx - 1)
		return chunk.substr(end_idx + 1)

	# if(cond)[body]
	if chunk.begins_with("if"):
		app.type = Type.BEGIN
		app.app1 = App.new()
		app.app1.type = Type.IF

		chunk = chunk.substr(2)
		app.app1.app1 = App.new()
		chunk = _parse(chunk, app.app1.app1)

		app.app1.app2 = App.new()
		chunk = _parse(chunk, app.app1.app2)

		if not chunk.is_empty():
			app.app2 = App.new()
			return _parse(chunk, app.app2)
		return chunk

	# while(cond)[body]
	if chunk.begins_with("while"):
		app.type = Type.BEGIN
		app.app1 = App.new()
		app.app1.type = Type.WHILE

		chunk = chunk.substr(5)
		app.app1.app1 = App.new()
		chunk = _parse(chunk, app.app1.app1)

		app.app1.app2 = App.new()
		chunk = _parse(chunk, app.app1.app2)

		if not chunk.is_empty():
			app.app2 = App.new()
			return _parse(chunk, app.app2)
		return chunk

	# [...] block
	if chunk.begins_with("["):
		var end_idx := _find_next(chunk, "[", "]")
		if end_idx < 0:
			push_warning("PotatoC: unmatched bracket in: %s" % chunk)
			return ""
		var inner := chunk.substr(1, end_idx - 1)

		app.type = Type.BEGIN
		app.app1 = App.new()
		_parse(inner, app.app1)

		return chunk.substr(end_idx + 1)

	# (...) grouping
	if chunk.begins_with("("):
		var end_idx := _find_next(chunk, "(", ")")
		if end_idx < 0:
			push_warning("PotatoC: unmatched bracket in: %s" % chunk)
			return ""
		var inner := chunk.substr(1, end_idx - 1)

		app.type = Type.BEGIN
		app.app1 = App.new()
		_parse(inner, app.app1)

		return chunk.substr(end_idx + 1)

	var nd := _next_delim(chunk)

	# Assignment: name:expr;
	if nd == 2:
		var colon_idx := chunk.find(":")
		var var_name := chunk.substr(0, colon_idx)

		chunk = chunk.substr(colon_idx + 1)
		var semi_idx := chunk.find(";")
		var expr_str := chunk.substr(0, semi_idx)
		chunk = chunk.substr(semi_idx + 1)

		var val_app := App.new()
		_parse(expr_str, val_app)

		if chunk.is_empty() or chunk.begins_with("]"):
			app.type = Type.ASSIGN
			app.app1 = val_app
			app.str_val = var_name
			return chunk

		app.type = Type.BEGIN
		app.app1 = App.new()
		app.app1.type = Type.ASSIGN
		app.app1.app1 = val_app
		app.app1.str_val = var_name

		app.app2 = App.new()
		return _parse(chunk, app.app2)

	# Local var declaration: #varname;
	if nd == 8:
		var semi_idx := chunk.find(";")
		var var_name := chunk.substr(1, semi_idx - 1)
		chunk = chunk.substr(semi_idx + 1)

		app.type = Type.BEGIN
		app.app1 = App.new()
		app.app1.type = Type.VARCREATE
		app.app1.str_val = var_name
		app.app2 = App.new()
		return _parse(chunk, app.app2)

	# Binary operators (by precedence from _next_delim)
	if nd == 4:  # +
		return _parse_binary_op(chunk, "+", Type.ADD, 1, app)
	if nd == 5:  # -
		return _parse_binary_op(chunk, "-", Type.SUBTRACT, 1, app)
	if nd == 6:  # *
		return _parse_binary_op(chunk, "*", Type.MULTIPLY, 1, app)
	if nd == 7:  # /
		return _parse_binary_op(chunk, "/", Type.DIVIDE, 1, app)
	if nd == 9:  # ||
		return _parse_binary_op(chunk, "||", Type.OR, 2, app)
	if nd == 10:  # &&
		return _parse_binary_op(chunk, "&&", Type.AND, 2, app)
	if nd == 11:  # !=
		return _parse_binary_op(chunk, "!=", Type.NOTEQUAL, 2, app)
	if nd == 14:  # <
		return _parse_binary_op(chunk, "<", Type.LESSTHAN, 1, app)
	if nd == 15:  # >
		return _parse_binary_op(chunk, ">", Type.GREATERTHAN, 1, app)
	if nd == 3:  # ==
		return _parse_binary_op(chunk, "==", Type.EQUALS, 2, app)

	# Function call or variable reference
	var paren_idx := chunk.find("(")
	if paren_idx != -1:
		var func_name := chunk.substr(0, paren_idx)
		var paren_end := _find_next(chunk.substr(paren_idx), "(", ")")
		if paren_end < 0:
			push_warning("PotatoC: unmatched bracket in: %s" % chunk)
			return ""
		var args_str := chunk.substr(paren_idx + 1, paren_end - 1)
		var after := chunk.substr(paren_idx + paren_end + 1)

		app.type = Type.BEGIN
		app.app1 = App.new()
		app.app1.type = Type.FUNCTION
		app.app1.str_val = func_name

		# Parse args (0-2, comma separated)
		if not args_str.is_empty():
			var comma_idx := args_str.find(",")
			if comma_idx != -1:
				var arg1_str := args_str.substr(0, comma_idx)
				var arg2_str := args_str.substr(comma_idx + 1)
				app.app1.app1 = App.new()
				_parse(arg1_str, app.app1.app1)
				app.app1.app2 = App.new()
				_parse(arg2_str, app.app1.app2)
			else:
				app.app1.app1 = App.new()
				_parse(args_str, app.app1.app1)

		if after.begins_with(";"):
			after = after.substr(1)
			if not after.is_empty():
				app.app2 = App.new()
				after = _parse(after, app.app2)

		return after
	else:
		# Variable reference (or numeric literal — getvar handles both)
		app.type = Type.VARREF
		app.str_val = chunk
		return ""


func _parse_binary_op(chunk: String, op: String, type: int, op_len: int, app: App) -> String:
	var idx := chunk.find(op)
	var lhs_str := chunk.substr(0, idx)
	var rhs_str := chunk.substr(idx + op_len)

	app.type = type
	app.app1 = App.new()
	_parse(lhs_str, app.app1)
	app.app2 = App.new()
	return _parse(rhs_str, app.app2)


# Port of C++ nextdelim.
func _next_delim(code: String) -> int:
	# Truncate at first ; or ( to match C++ behavior
	var truncated := code
	var semi_idx := code.find(";")
	var paren_idx := code.find("(")

	if semi_idx != -1:
		truncated = code.substr(0, semi_idx)
	if paren_idx != -1 and (semi_idx == -1 or paren_idx < semi_idx):
		truncated = code.substr(0, paren_idx)

	var best := 0  # default to index 0
	for x in range(DELIMS.size()):
		var found := truncated.find(DELIMS[x])
		var best_found := truncated.find(DELIMS[best])
		if found != -1:
			if best_found == -1 or DELIM_VALUES[x] > DELIM_VALUES[best]:
				best = x
			elif DELIM_VALUES[x] == DELIM_VALUES[best] and found <= best_found:
				best = x

	return best


func _find_next(s: String, c1: String, c2: String) -> int:
	var level := 0
	for i in range(s.length()):
		if s[i] == c1:
			level += 1
		if s[i] == c2:
			level -= 1
		if level == 0:
			return i
	return -1


func _execute(app: App, local_vars: Dictionary) -> int:
	if app == null:
		return 0

	match app.type:
		Type.NONE:
			return 0

		Type.BEGIN:
			var val := 0
			if app.app1:
				val = _execute(app.app1, local_vars)
			if app.app2:
				val = _execute(app.app2, local_vars)
			return val

		Type.VARCREATE:
			local_vars[app.str_val] = 0
			return 0

		Type.ASSIGN:
			var val := _execute(app.app1, local_vars)
			_set_var(app.str_val, val, local_vars)
			return val

		Type.VARREF:
			return _get_var(app.str_val, local_vars)

		Type.IF:
			if _execute(app.app1, local_vars) != 0:
				return _execute(app.app2, local_vars)
			return 0

		Type.WHILE:
			var val := 0
			while _execute(app.app1, local_vars) != 0:
				val = _execute(app.app2, local_vars)
			return val

		Type.EQUALS:
			return int(_execute(app.app1, local_vars) == _execute(app.app2, local_vars))
		Type.NOTEQUAL:
			return int(_execute(app.app1, local_vars) != _execute(app.app2, local_vars))
		Type.LESSTHAN:
			return int(_execute(app.app1, local_vars) < _execute(app.app2, local_vars))
		Type.GREATERTHAN:
			return int(_execute(app.app1, local_vars) > _execute(app.app2, local_vars))

		Type.ADD:
			return _execute(app.app1, local_vars) + _execute(app.app2, local_vars)
		Type.SUBTRACT:
			return _execute(app.app1, local_vars) - _execute(app.app2, local_vars)
		Type.MULTIPLY:
			return _execute(app.app1, local_vars) * _execute(app.app2, local_vars)
		Type.DIVIDE:
			var divisor := _execute(app.app2, local_vars)
			if divisor == 0:
				return 0
			@warning_ignore("integer_division")
			return _execute(app.app1, local_vars) / divisor

		Type.OR:
			return int(_execute(app.app1, local_vars) != 0 or _execute(app.app2, local_vars) != 0)
		Type.AND:
			return int(_execute(app.app1, local_vars) != 0 and _execute(app.app2, local_vars) != 0)

		Type.FUNCTION:
			if function_handler.is_valid():
				return function_handler.call(app, local_vars)
			return 0

		Type.STRING:
			return 0

	return 0


func _get_var(var_name: String, local_vars: Dictionary) -> int:
	if local_vars.has(var_name):
		return local_vars[var_name]
	if global_vars.has(var_name):
		return global_vars[var_name]
	# Fallback: interpret as integer literal
	if var_name.is_valid_int():
		return int(var_name)
	return 0


func _set_var(var_name: String, val: int, local_vars: Dictionary) -> void:
	if local_vars.has(var_name):
		local_vars[var_name] = val
		return
	if global_vars.has(var_name):
		global_vars[var_name] = val
		return
	# If not found anywhere, set in local (shouldn't normally happen)
	local_vars[var_name] = val


# Port of C++ clean.
static func clean(code: String) -> String:
	var result := ""
	var in_quotes := false
	var i := 0
	while i < code.length():
		var c := code[i]
		if c == "'":
			in_quotes = not in_quotes
			result += c
			i += 1
			continue

		# Strip whitespace outside quotes
		if not in_quotes and (c == " " or c == "\n" or c == "\t" or c == "\r"):
			i += 1
			continue

		# Convert = to : unless part of ==, !=
		# C++: keep = if prev is '!' (!=), prev is '=' (second of ==), or next is '=' (first of ==)
		if not in_quotes and c == "=":
			if i > 0 and code[i - 1] == "!":
				result += c
			elif i > 0 and code[i - 1] == "=":
				result += c
			elif i + 1 < code.length() and code[i + 1] == "=":
				result += c
			else:
				result += ":"
			i += 1
			continue

		result += c
		i += 1
	return result


# Helper to get string value from an App node (for function args)
func get_string_arg(app: App, local_vars: Dictionary) -> String:
	if app == null:
		return ""
	if app.type == Type.STRING:
		return app.str_val
	# For BEGIN wrapping a STRING
	if app.type == Type.BEGIN and app.app1 and app.app1.type == Type.STRING:
		return app.app1.str_val
	# Fallback: evaluate as int and convert
	return str(_execute(app, local_vars))
