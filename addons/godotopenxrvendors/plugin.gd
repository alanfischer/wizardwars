@tool
extends EditorPlugin

var _export_plugin: GodotOpenXRVendorsExportPlugin


func _enter_tree() -> void:
	_export_plugin = GodotOpenXRVendorsExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class GodotOpenXRVendorsExportPlugin extends EditorExportPlugin:
	func _get_name() -> String:
		return "GodotOpenXRVendors"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(
			platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		if not _supports_platform(platform):
			return PackedStringArray()
		var build_type := "debug" if debug else "release"
		return PackedStringArray([
			"res://addons/godotopenxrvendors/.bin/android/%s/godotopenxr-meta-%s.aar" % [build_type, build_type]
		])
