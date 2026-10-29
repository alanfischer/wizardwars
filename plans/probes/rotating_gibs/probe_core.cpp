// Same bodies, but the floor is a plain hop aa_box solid — no BSP traceable anywhere.
#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T = double;
using V = hop::vec3<T>;
static V vec(T x, T y, T z) { V v; v.set(x, y, z); return v; }

static V ROD_I = vec(0.005, 0.09, 0.09);

static std::shared_ptr<hop::simulator<T>> world_with_box_floor() {
	auto sim = std::make_shared<hop::simulator<T>>();
	sim->set_gravity(vec(0, -20, 0));
	sim->set_default_contact_mode(hop::contact_mode::speculative);
	auto f = std::make_shared<hop::solid<T>>();
	f->set_infinite_mass();
	f->set_coefficient_of_gravity(T {});
	f->add_shape(std::make_shared<hop::shape<T>>(
	    hop::aa_box<T>(vec(-12, -1, -12), vec(12, 0, 12))));
	sim->add_solid(f);
	return sim;
}
static std::shared_ptr<hop::solid<T>> make_rod(T half_len, T radius) {
	auto s = std::make_shared<hop::solid<T>>();
	s->add_shape(std::make_shared<hop::shape<T>>(
	    hop::capsule<T>(vec(-half_len,0,0), vec(2*half_len,0,0), radius)));
	s->set_mass((T)1); s->set_inertia(ROD_I);
	return s;
}
static std::shared_ptr<hop::solid<T>> make_box(T hx, T hy, T hz) {
	auto s = std::make_shared<hop::solid<T>>();
	s->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hx,-hy,-hz), vec(hx,hy,hz))));
	s->set_mass((T)1); s->set_inertia(ROD_I);
	return s;
}
static std::shared_ptr<hop::solid<T>> make_sphere(T r) {
	auto s = std::make_shared<hop::solid<T>>();
	s->add_shape(std::make_shared<hop::shape<T>>(hop::sphere<T>(vec(0,0,0), r)));
	s->set_mass((T)1); s->set_inertia(ROD_I);
	return s;
}
static double energy(std::shared_ptr<hop::solid<T>> b) {
	const V v = b->get_velocity(), w = b->get_angular_velocity();
	hop::mat3<T> Rt; hop::transpose(Rt, b->get_orientation());
	V wb; hop::mul(wb, Rt, w);
	return 0.5*((double)v.x*v.x+(double)v.y*v.y+(double)v.z*v.z)
	     + 0.5*((double)wb.x*wb.x*(double)ROD_I.x+(double)wb.y*wb.y*(double)ROD_I.y+(double)wb.z*wb.z*(double)ROD_I.z)
	     + 20.0*(double)b->get_position().y;
}
static void run(const char *label, std::shared_ptr<hop::solid<T>> b, V w0, T y0) {
	auto sim = world_with_box_floor();
	b->set_position(vec(0, y0, 0));
	b->set_angular_velocity(w0);
	sim->add_solid(b);
	printf("%-32s", label);
	for (int i = 0; i < 300; ++i) {
		sim->update((T)(1.0/60.0));
		if (i==59||i==179||i==299)
			printf("  t=%3d |w|=%7.3f E=%8.4f y=%.4f", i+1,
			       (double)hop::length(b->get_angular_velocity()), energy(b), (double)b->get_position().y);
	}
	printf("\n");
}
int main() {
	printf("=== plain hop box floor, no BSP traceable ===\n");
	run("BIG capsule spun ABOUT spine",  make_rod(0.512, 0.1), vec(10,0,0), 0.15);
	run("BIG capsule spun ACROSS spine", make_rod(0.512, 0.1), vec(0,0,10), 0.15);
	run("BIG capsule at rest",           make_rod(0.512, 0.1), vec(0,0,0),  0.15);
	run("BIG sphere r=0.1",              make_sphere(0.1),     vec(10,0,0), 0.15);
	run("BIG box .512x.1x.1 about Z",    make_box(0.512,0.1,0.1), vec(0,0,10), 0.15);
	run("BIG box .512x.1x.1 at rest",    make_box(0.512,0.1,0.1), vec(0,0,0),  0.15);
	return 0;
}
