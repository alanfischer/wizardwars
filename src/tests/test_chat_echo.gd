extends "res://src/tests/test_base.gd"
## The listen host is the sender of its own chat and also the authority that broadcasts it, and a
## call_remote RPC skips the sending process — so a call_remote sync_chat means the host says
## something to the world and never sees its own line. command_system's _reply/_announce carry an
## explicit local echo for the Server voice; chat has no such echo, so the flag is the whole fix.


func test_sync_chat_reaches_the_sending_host() -> void:
	var script: Script = NetworkManager.get_script()
	var cfg: Dictionary = script.get_rpc_config()
	assert_true(cfg.has("sync_chat"), "sync_chat is no longer an @rpc; this test needs a new target")
	var chat: Dictionary = cfg["sync_chat"]
	assert_true(bool(chat["call_local"]),
		"sync_chat is call_remote, so the listen host will not see its own message")
