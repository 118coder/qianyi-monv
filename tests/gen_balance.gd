extends SceneTree
## 生成 data/balance.json：godot --headless -s res://tests/gen_balance.gd

func _initialize() -> void:
	var d := ArpgBalance.defaults()
	DirAccess.make_dir_recursive_absolute("res://data")
	var f := FileAccess.open("res://data/balance.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	print("balance.json written, keys=", d.keys().size())
	quit(0)
