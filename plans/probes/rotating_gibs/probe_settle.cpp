// Why an aa_box gib with rotation enabled never settles on a BSP floor.
//
// Not an energy probe. The BSP column of the bug-3 table is already 1.00x — these
// gibs conserve energy fine. The question here is the other one: a body can conserve
// energy perfectly and still never come to rest. Four measurements:
//
//   A. sphere equivalence   - a box and a sphere of its half-height are the SAME body
//   B. spin conservation    - w.n (spin about the floor normal) is never damped
//   C. no rest attitude     - resting height is orientation-independent
//   D. what would fix it    - angular damp, which hop-godot never applies
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <memory>
#include <vector>
#include <hop/hop.h>
#include "hop_bsp_traceable.h"
using T = double; using V = hop::vec3<T>;
using namespace hop_bsp;
#include "bsp_fixtures.h"

static const double DT = 1.0 / 60.0;

// hop-godot gives dynamic bodies speculative contacts, friction 1, bounce 0.
struct World {
	std::shared_ptr<hop::simulator<T>> sim;
	std::shared_ptr<hop::solid<T>> world;
	std::vector<uint8_t> blob;
	explicit World(bool bsp) {
		sim = std::make_shared<hop::simulator<T>>();
		sim->set_gravity(vec(0, -20, 0));
		sim->set_default_contact_mode(hop::contact_mode::speculative);
		world = std::make_shared<hop::solid<T>>();
		world->set_infinite_mass();
		world->set_coefficient_of_gravity(T {});
		world->set_coefficient_of_static_friction(1);
		world->set_coefficient_of_dynamic_friction(1);
		if (bsp) {
			// make_floor_map()'s slab is only +-12.8 m; a gib that never stops rolls
			// off it. Use the full GoldSrc extent so "it left the map" is a finding,
			// not the fixture.
			const double mins[3] = { -4096, -4096, -64 }, maxs[3] = { 4096, 4096, 0 };
			blob = make_box_map(mins, maxs);
			auto tr = std::make_unique<HopBspTraceable<T>>();
			assert(tr->build(blob.data(), blob.size(), 0, (T)SCALE, hopbsp::BLOCK_SOLID));
			world->add_shape(std::make_shared<hop::shape<T>>(std::move(tr)));
		} else {
			hop::aa_box<T> floor;
			floor.mins.set(-50, -1, -50);
			floor.maxs.set(50, 0, 50);
			world->add_shape(std::make_shared<hop::shape<T>>(floor));
		}
		sim->add_solid(world);
	}
};

static V box_inertia(V h, double m) {  // half-extents
	const double x = 2 * h.x, y = 2 * h.y, z = 2 * h.z;
	return vec((T)(m * (y * y + z * z) / 12), (T)(m * (x * x + z * z) / 12), (T)(m * (x * x + y * y) / 12));
}

static std::shared_ptr<hop::solid<T>> add_box(World &w, V h, double m, V pos, V v, V om, double adamp_unused = 0) {
	(void)adamp_unused;
	auto s = std::make_shared<hop::solid<T>>();
	hop::aa_box<T> b;
	b.mins.set(-h.x, -h.y, -h.z);
	b.maxs.set(h.x, h.y, h.z);
	s->add_shape(std::make_shared<hop::shape<T>>(b));
	s->set_mass((T)m);
	s->set_inertia(box_inertia(h, m));
	s->set_coefficient_of_static_friction(1);
	s->set_coefficient_of_dynamic_friction(1);
	s->set_coefficient_of_restitution(0);
	s->set_position(pos);
	s->set_velocity(v);
	s->set_angular_velocity(om);
	w.sim->add_solid(s);
	return s;
}

static std::shared_ptr<hop::solid<T>> add_sphere(World &w, double r, double m, V pos, V v, V om,
                                                const V *inertia = nullptr) {
	auto s = std::make_shared<hop::solid<T>>();
	s->add_shape(std::make_shared<hop::shape<T>>(hop::sphere<T>(vec(0, 0, 0), (T)r)));
	s->set_mass((T)m);
	const double i = 0.4 * m * r * r;
	s->set_inertia(inertia ? *inertia : vec((T)i, (T)i, (T)i));
	s->set_coefficient_of_static_friction(1);
	s->set_coefficient_of_dynamic_friction(1);
	s->set_coefficient_of_restitution(0);
	s->set_position(pos);
	s->set_velocity(v);
	s->set_angular_velocity(om);
	w.sim->add_solid(s);
	return s;
}

// Godot's own integrator, which hop-godot applies only when body->angular_damp > 0.
static void damp(std::shared_ptr<hop::solid<T>> &s, double d) {
	if (d <= 0) return;
	V om = s->get_angular_velocity();
	hop::mul(om, (T)std::fmax(0.0, 1.0 - d * DT));
	s->set_angular_velocity(om);
}

// A real WW gib: bone-sized, 0.2 kg.
static const V GIB = vec(0.06, 0.012, 0.035);  // half-extents, metres

static hop::quat<T> aa(V axis, double ang) {
	hop::quat<T> q; hop::set_quat_from_axis_angle(q, axis, (T)ang); return q;
}

static void hdr(const char *s) { printf("\n=== %s\n", s); }

// Total mechanical energy about the floor plane: translation + rotation + gravity.
// Rotational term in the BODY frame, where the inertia is the stored diagonal.
static double energy(const std::shared_ptr<hop::solid<T>> &s, double m, double g) {
	const double v = (double)hop::length(s->get_velocity());
	hop::mat3<T> Rt; hop::transpose(Rt, s->get_orientation());
	V wb; hop::mul(wb, Rt, s->get_angular_velocity());
	const V I = s->get_inertia();
	const double rot = 0.5 * ((double)I.x * (double)wb.x * (double)wb.x +
	                          (double)I.y * (double)wb.y * (double)wb.y +
	                          (double)I.z * (double)wb.z * (double)wb.z);
	return 0.5 * m * v * v + rot + m * g * (double)s->get_position().y;
}

int main() {
	// ---------------------------------------------------------------- A
	hdr("A. against a BSP floor a box IS a sphere of its half-height");
	printf("Same launch, 20 s. If the trace saw shape, these would diverge.\n");
	printf("%-22s %-10s %-10s %-10s %-10s\n", "body", "y end", "|v| end", "|w| end", "dist");
	for (int k = 0; k < 2; ++k) {
		World w(true);
		const V p0 = vec(0, 0.8, 0), v0 = vec(1.4, 0, -0.6), w0 = vec(3, 2, 5);
		auto box = add_box(w, GIB, 0.2, p0, v0, w0);
		auto sph = add_sphere(w, GIB.y, 0.2, vec(0.5, 0.8, 0), v0, w0);
		const V bi = box_inertia(GIB, 0.2);
		auto twin = add_sphere(w, GIB.y, 0.2, vec(1.0, 0.8, 0), v0, w0, &bi);
		if (k == 1) box->set_orientation_from_quat(aa(vec(0, 0, 1), M_PI / 2));
		for (int i = 0; i < 1200; ++i) w.sim->update((T)DT);
		auto row = [](const char *n, std::shared_ptr<hop::solid<T>> &s, double x0) {
			V p = s->get_position();
			printf("%-22s %-10.4f %-10.4f %-10.4f %-10.4f\n", n, (double)p.y,
			       (double)hop::length(s->get_velocity()), (double)hop::length(s->get_angular_velocity()),
			       std::hypot((double)p.x - x0, (double)p.z));
		};
		printf("%s\n", k == 0 ? "-- box flat" : "-- box tipped 90 deg onto its end");
		row("gib box", box, 0);
		row("sphere, sphere inertia", sph, 0.5);
		row("sphere, BOX's inertia", twin, 1.0);
	}

	// ---------------------------------------------------------------- B
	hdr("B. the contact lever is exactly -n*reach, so spin about n is conserved");
	{
		World w(true);
		auto s = add_box(w, GIB, 0.2, vec(0, 0.4, 0), vec(0.9, 0, 0), vec(0, 8, 0));
		printf("%-6s %-9s %-9s %-9s %-9s %-9s %-9s %-9s\n", "t(s)", "w.n (spin)", "|w_tan|", "|v|", "w*r", "dist(m)", "lever.n", "asleep");
		for (int i = 0; i <= 3600; ++i) {
			if (i % 600 == 0) {
				V om = s->get_angular_velocity();
				const V n = vec(0, 1, 0);
				const double wn = (double)hop::dot(om, n);
				V tan = om, proj; hop::mul(proj, n, (T)wn); hop::sub(tan, proj);
				double lv = NAN;
				for (int t = 0; t < s->get_touch_count(); ++t) {
					const auto &tc = s->get_touch(t);
					const double L = (double)hop::length(tc.lever);
					if (L > 1e-9) lv = (double)hop::dot(tc.lever, tc.normal) / L;
				}
				printf("%-6.0f %-9.4f %-9.4f %-9.4f %-9.4f %-9.4f %-9.4f %-9s\n", i * DT, wn,
				       (double)hop::length(tan), (double)hop::length(s->get_velocity()),
				       (double)hop::length(tan) * (double)GIB.y,
				       std::hypot((double)s->get_position().x, (double)s->get_position().z),
				       lv, s->active() ? "no" : "YES");
			}
			w.sim->update((T)DT);
		}
	}

	// ---------------------------------------------------------------- C
	hdr("C. no rest attitude: resting height is the same whatever the gib lies on");
	printf("A real box settles onto its widest face. Here every attitude rests at half-Y.\n");
	printf("%-26s %-12s %-12s\n", "dropped rotated about", "rest y", "expected flat");
	{
		struct { const char *n; V ax; double a; } cases[] = {
			{ "nothing (flat)", vec(1, 0, 0), 0 },
			{ "Z by 90 deg (on end)", vec(0, 0, 1), M_PI / 2 },
			{ "X by 90 deg (on edge)", vec(1, 0, 0), M_PI / 2 },
			{ "X by 45 deg (corner)", vec(1, 0, 0), M_PI / 4 },
		};
		for (auto &c : cases) {
			World w(true);
			auto s = add_box(w, GIB, 0.2, vec(0, 0.5, 0), vec(0, 0, 0), vec(0, 0, 0));
			s->set_orientation_from_quat(aa(c.ax, c.a));
			for (int i = 0; i < 600; ++i) w.sim->update((T)DT);
			printf("%-26s %-12.4f %-12.4f\n", c.n, (double)s->get_position().y, (double)GIB.y);
		}
	}

	// ---------------------------------------------------------------- D
	hdr("D. angular damp is the only thing that stops it, and hop-godot never applies it");
	printf("Godot's default_angular_damp is 0.1; hop-godot damps only when the BODY sets it.\n");
	printf("%-16s %-12s %-12s %-12s %-12s %-12s\n", "angular_damp", "|w| @ 60s", "|v| @ 60s", "dist(m)", "touches", "slept at");
	for (double d : { 0.0, 0.1, 1.0, 5.0 }) {
		World w(true);
		auto s = add_box(w, GIB, 0.2, vec(0, 0.4, 0), vec(0.9, 0, 0), vec(0, 8, 0));
		double slept = -1;
		for (int i = 0; i <= 3600; ++i) {
			damp(s, d);
			w.sim->update((T)DT);
			if (slept < 0 && !s->active()) slept = i * DT;
		}
		char sl[32];
		if (slept < 0) snprintf(sl, sizeof sl, "never"); else snprintf(sl, sizeof sl, "%.1f s", slept);
		printf("%-16.2f %-12.4f %-12.4f %-12.4f %-12d %-12s\n", d,
		       (double)hop::length(s->get_angular_velocity()),
		       (double)hop::length(s->get_velocity()),
		       std::hypot((double)s->get_position().x, (double)s->get_position().z),
		       s->get_touch_count(), sl);
	}
	printf("\nsleep needs |w| < deactivate_speed (0.2 rad/s) -- simulator.h:1121\n");

	// ---------------------------------------------------------------- E
	hdr("E. even fully stopped it never sleeps -- the resting gap is not 'support'");
	printf("try_deactivate wants a touch with separation <= spec_slop OR accum_n > 0.\n");
	printf("%-12s %-10s %-10s %-12s %-12s %-10s %-10s\n",
	       "floor", "rest y", "gap", "separation", "accum_n", "fresh", "slept at");
	for (int bsp = 1; bsp >= 0; --bsp) {
		World w(bsp != 0);
		// Placed at rest, no spin at all: nothing left to dissipate.
		auto s = add_box(w, GIB, 0.2, vec(0, 0.3, 0), vec(0, 0, 0), vec(0, 0, 0));
		double slept = -1;
		for (int i = 0; i <= 1800; ++i) {
			w.sim->update((T)DT);
			if (slept < 0 && !s->active()) slept = i * DT;
		}
		double sep = NAN, an = NAN; int fresh = 0;
		for (int t = 0; t < s->get_touch_count(); ++t) {
			const auto &tc = s->get_touch(t);
			sep = (double)tc.separation; an = (double)tc.accum_n;
			fresh = 1;  // presence in the cache after the final step
		}
		char sl[32];
		if (slept < 0) snprintf(sl, sizeof sl, "never"); else snprintf(sl, sizeof sl, "%.2f s", slept);
		printf("%-12s %-10.5f %-10.5f %-12.6f %-12.6f %-10d %-10s\n",
		       bsp ? "BSP hull" : "aa_box", (double)s->get_position().y,
		       (double)s->get_position().y - (double)GIB.y, sep, an, fresh, sl);
	}

	// ---------------------------------------------------------------- F
	hdr("F. the catch-22: damping the spin is what stops the body sleeping");
	printf("solid::set_angular_velocity calls activate() (solid.h:228-231), and hop-godot's\n");
	printf("damp loop (hop_physics_server.cpp:2326) calls it EVERY step. The sleep counter\n");
	printf("needs 32 consecutive still ticks and is reset before it can reach 2.\n");
	printf("%-34s %-12s %-12s %-12s\n", "angular damp applied", "|w| @ 60s", "|v| @ 60s", "slept at");
	for (int mode = 0; mode < 3; ++mode) {
		World w(true);
		auto s = add_box(w, GIB, 0.2, vec(0, 0.4, 0), vec(0.9, 0, 0), vec(0, 8, 0));
		double slept = -1;
		for (int i = 0; i <= 3600; ++i) {
			if (mode == 1) damp(s, 2.0);                                        // hop-godot as written
			if (mode == 2 && hop::length(s->get_angular_velocity()) > (T)0.2)   // skip the no-op write
				damp(s, 2.0);
			w.sim->update((T)DT);
			if (slept < 0 && !s->active()) slept = i * DT;
		}
		char sl[32];
		if (slept < 0) snprintf(sl, sizeof sl, "never"); else snprintf(sl, sizeof sl, "%.2f s", slept);
		const char *n = mode == 0 ? "none (damp = 0, today's gib)"
		              : mode == 1 ? "every tick (hop-godot's loop)"
		                          : "only while |w| > sleep speed";
		printf("%-34s %-12.4f %-12.4f %-12s\n", n,
		       (double)hop::length(s->get_angular_velocity()),
		       (double)hop::length(s->get_velocity()), sl);
	}
	// ---------------------------------------------------------------- G
	hdr("G. energy: lively launches DO gain it, and the roll is never slow");
	printf("Mechanical energy about the floor, after the landing transient (t = 5 s = 1.00).\n");
	printf("A gib is a ball of radius half-Y carrying a whole bone's rotational inertia:\n");
	{
		const V I = box_inertia(GIB, 0.2);
		printf("  I_long / (m r^2) = %.2f   (a solid sphere is 0.40, a hoop is 1.00)\n",
		       (double)I.x / (0.2 * (double)GIB.y * (double)GIB.y));
	}
	printf("%-26s %-9s %-9s %-9s %-9s %-9s %-9s\n",
	       "launch", "E @5s(J)", "E30/E5", "E60/E5", "v @60s", "w @60s", "spin/tot");
	{
		struct { const char *n; V v; V w; } launches[] = {
			{ "thrown flat, spinning", vec(1.4, 0, -0.6), vec(3, 2, 5) },
			{ "tumbling hard", vec(2.5, 1.0, 0), vec(9, 3, 5) },
			{ "dropped, barely moving", vec(0.15, 0, 0), vec(0, 0, 0) },
			{ "dropped dead still", vec(0, 0, 0), vec(0, 0, 0) },
		};
		for (auto &L : launches) {
			World w(true);
			auto s = add_box(w, GIB, 0.2, vec(0, 0.5, 0), L.v, L.w);
			double e5 = 0, e30 = 0;
			for (int i = 0; i <= 3600; ++i) {
				if (i == 300) e5 = energy(s, 0.2, 20);
				if (i == 1800) e30 = energy(s, 0.2, 20);
				w.sim->update((T)DT);
			}
			const double e60 = energy(s, 0.2, 20);
			// How much of the kinetic total is in spin rather than travel.
			const double vv = (double)hop::length(s->get_velocity());
			const double lin = 0.5 * 0.2 * vv * vv;
			const double kin = e60 - 0.2 * 20 * (double)s->get_position().y;
			printf("%-26s %-9.4f %-9.3f %-9.3f %-9.4f %-9.2f %-9.3f\n", L.n, e5,
			       e5 != 0 ? e30 / e5 : 0.0, e5 != 0 ? e60 / e5 : 0.0, vv,
			       (double)hop::length(s->get_angular_velocity()),
			       kin > 0 ? (kin - lin) / kin : 0.0);
		}
	}
	printf("\nFor scale: a gib is 12 cm long. 0.6 m/s is ~5 body-lengths a second,\n");
	printf("held forever. GoldSrc units: 0.6 / 0.025 = 24 u/s.\n");

	// ---------------------------------------------------------------- H
	hdr("H. the gain is bug 1, and it is continuous, not a landing injection");
	printf("Same aa_box shape and same launch; only the INERTIA TENSOR changes. The BSP\n");
	printf("contact cannot tell these apart (finding A), so any difference is integrate_angular.\n");
	printf("w x (I.w) is identically zero for isotropic I, which gates bug 1 off.\n");
	printf("%-28s %-9s %-9s %-9s %-9s %-9s\n", "inertia", "E@5s", "E10/E5", "E20/E5", "E40/E5", "E60/E5");
	{
		const V aniso = box_inertia(GIB, 0.2);
		// Isotropic, matched to the box's mean so the magnitudes stay comparable.
		const double mean = ((double)aniso.x + (double)aniso.y + (double)aniso.z) / 3.0;
		const V iso = vec((T)mean, (T)mean, (T)mean);
		struct { const char *n; V I; } rows[] = {
			{ "box (anisotropic, 1:3.5)", aniso },
			{ "same box, isotropic I", iso },
		};
		for (auto &r : rows) {
			World w(true);
			auto s = add_box(w, GIB, 0.2, vec(0, 0.5, 0), vec(1.4, 0, -0.6), vec(3, 2, 5));
			s->set_inertia(r.I);
			double e[5] = { 0, 0, 0, 0, 0 };
			const int at[5] = { 300, 600, 1200, 2400, 3600 };
			for (int i = 0; i <= 3600; ++i) {
				for (int k = 0; k < 5; ++k) if (i == at[k]) e[k] = energy(s, 0.2, 20);
				w.sim->update((T)DT);
			}
			printf("%-28s %-9.4f %-9.3f %-9.3f %-9.3f %-9.3f\n", r.n, e[0],
			       e[1] / e[0], e[2] / e[0], e[3] / e[0], e[4] / e[0]);
		}
	}
	printf("\nThe gain is not unbounded here: it plateaus because the angular cap\n");
	printf("(max_angular_velocity_component, 50 rad/s) clamps it. Which sets the roll:\n");

	// ---------------------------------------------------------------- I
	hdr("I. the terminal roll speed is the angular cap times the gib's half-height");
	printf("Rolling without slipping ties v to w. Bug 1 pins w at the cap. So the speed a\n");
	printf("gib cruises off at is a solver constant, not anything about how it was thrown.\n");
	printf("%-12s %-14s %-14s %-14s %-10s\n", "cap (rad/s)", "|w| @60s", "|v| @60s (m/s)", "predicted cap*r", "u/s");
	for (double cap : { 12.5, 25.0, 50.0, 100.0 }) {
		World w(true);
		w.sim->set_max_angular_velocity_component((T)cap);
		auto s = add_box(w, GIB, 0.2, vec(0, 0.5, 0), vec(1.4, 0, -0.6), vec(3, 2, 5));
		for (int i = 0; i <= 3600; ++i) w.sim->update((T)DT);
		const double vv = (double)hop::length(s->get_velocity());
		printf("%-12.1f %-14.2f %-14.4f %-14.4f %-10.1f\n", cap,
		       (double)hop::length(s->get_angular_velocity()), vv, cap * (double)GIB.y, vv / 0.025);
	}

	// ---------------------------------------------------------------- J
	hdr("J. the long run: does it ever actually stop?");
	printf("300 s. Sleep needs |w| < 0.2 rad/s for 32 consecutive ticks AND a supported contact.\n");
	printf("%-26s %-10s %-10s %-10s %-10s %-10s\n",
	       "launch", "|v| @60s", "|v| @300s", "|w| @300s", "dist(m)", "slept at");
	{
		struct { const char *n; V v; V w; } launches[] = {
			{ "thrown flat, spinning", vec(1.4, 0, -0.6), vec(3, 2, 5) },
			{ "tumbling hard", vec(2.5, 1.0, 0), vec(9, 3, 5) },
			{ "dropped, barely moving", vec(0.15, 0, 0), vec(0, 0, 0) },
		};
		for (auto &L : launches) {
			World w(true);
			auto s = add_box(w, GIB, 0.2, vec(0, 0.5, 0), L.v, L.w);
			double v60 = 0, slept = -1;
			for (int i = 0; i <= 18000; ++i) {
				w.sim->update((T)DT);
				if (i == 3600) v60 = (double)hop::length(s->get_velocity());
				if (slept < 0 && !s->active()) slept = i * DT;
			}
			char sl[32];
			if (slept < 0) snprintf(sl, sizeof sl, "never"); else snprintf(sl, sizeof sl, "%.1f s", slept);
			printf("%-26s %-10.4f %-10.4f %-10.4f %-10.3f %-10s\n", L.n, v60,
			       (double)hop::length(s->get_velocity()),
			       (double)hop::length(s->get_angular_velocity()),
			       std::hypot((double)s->get_position().x, (double)s->get_position().z), sl);
		}
	}
	return 0;
}
