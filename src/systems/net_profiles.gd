extends RefCounted

## Simulated connections to join through, to play a real server over a slow or lossy link with
## nothing set on the server. Each is goldnet's network sim for both legs, run on this client: `up`
## on what it sends (sim_config), `down` on what it receives (recv_sim_config). Latency is per leg
## and adds to whatever the real connection already has.

const OFF := "off"

## In menu order.
const PROFILES := {
	"off": {
		"name": "Off",
		"info": "Your real connection, nothing added.",
		"up": {},
		"down": {},
	},
	"cable": {
		"name": "Cable",
		"info": "10-20 ms each way, 1% loss down.",
		"up": {"latency_min_ms": 10, "latency_max_ms": 20},
		"down": {"latency_min_ms": 10, "latency_max_ms": 20, "loss_percent": 1},
	},
	"dsl": {
		"name": "DSL",
		"info": "20-35 ms each way, 1.5 Mbit down, 384 kbit up.",
		"up": {"latency_min_ms": 20, "latency_max_ms": 35, "link_bps": 48000},
		"down": {"latency_min_ms": 20, "latency_max_ms": 35, "link_bps": 187500},
	},
	"mobile": {
		"name": "Mobile",
		"info": "30-90 ms each way, 2-3% loss, and a 400 ms stall every 8 s.",
		"up": {"latency_min_ms": 30, "latency_max_ms": 90, "loss_percent": 2},
		"down": {"latency_min_ms": 30, "latency_max_ms": 90, "loss_percent": 3,
			"spike_ms": 400, "spike_interval_s": 8.0, "spike_duration_s": 0.3},
	},
	"modem56": {
		"name": "56k modem",
		"info": "75-110 ms each way, 6000 B/s down, 3500 B/s up, 1% loss down.",
		"up": {"latency_min_ms": 75, "latency_max_ms": 110, "link_bps": 3500},
		"down": {"latency_min_ms": 75, "latency_max_ms": 110, "link_bps": 6000, "loss_percent": 1},
	},
	"modem28": {
		"name": "28.8k modem",
		"info": "90-130 ms each way, 3200 B/s each way, 1% loss down.",
		"up": {"latency_min_ms": 90, "latency_max_ms": 130, "link_bps": 3200},
		"down": {"latency_min_ms": 90, "latency_max_ms": 130, "link_bps": 3200, "loss_percent": 1},
	},
}


static func display_name(id: String) -> String:
	return PROFILES.get(id, PROFILES[OFF])["name"]


## Sets both legs on a goldnet MultiplayerAPI. False on stock, or a goldnet without the receive sim.
static func apply(mp: MultiplayerAPI, id: String) -> bool:
	if not "recv_sim_config" in mp:
		return false
	var p: Dictionary = PROFILES.get(id, PROFILES[OFF])
	mp.sim_config = p["up"]
	mp.recv_sim_config = p["down"]
	return true
