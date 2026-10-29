#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T = double; using V = hop::vec3<T>;
static V vec(T x, T y, T z){ V v; v.set(x,y,z); return v; }
static V I3 = vec(0.005, 0.09, 0.09);
int main(int argc, char **argv) {
	const double half_len = argc > 1 ? atof(argv[1]) : 0.512;
	const double w0 = argc > 2 ? atof(argv[2]) : 10.0;
	auto sim = std::make_shared<hop::simulator<T>>();
	sim->set_gravity(vec(0,-20,0));
	sim->set_default_contact_mode(hop::contact_mode::speculative);
	auto f = std::make_shared<hop::solid<T>>();
	f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
	f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-12,-1,-12), vec(12,0,12))));
	sim->add_solid(f);

	auto s = std::make_shared<hop::solid<T>>();
	s->add_shape(std::make_shared<hop::shape<T>>(
	    hop::capsule<T>(vec(-half_len,0,0), vec(2*half_len,0,0), 0.1)));
	s->set_mass((T)1); s->set_inertia(I3);
	s->set_coefficient_of_static_friction(T{});   // mu = 0: isolate the normal impulse
	s->set_coefficient_of_dynamic_friction(T{});
	s->set_position(vec(0, 0.15, 0));
	s->set_angular_velocity(vec((T)w0, 0, 0));
	sim->add_solid(s);

	printf("frame   y       vy       wx      wy      wz    |  n_touch  lever(x,y,z)          E\n");
	for (int i = 0; i < 120; ++i) {
		sim->update((T)(1.0/60.0));
		const V p = s->get_position(), v = s->get_velocity(), w = s->get_angular_velocity();
		hop::mat3<T> Rt; hop::transpose(Rt, s->get_orientation());
		V wb; hop::mul(wb, Rt, w);
		const double E = 0.5*((double)v.x*v.x+(double)v.y*v.y+(double)v.z*v.z)
		    + 0.5*((double)wb.x*wb.x*0.005+(double)wb.y*wb.y*0.09+(double)wb.z*wb.z*0.09)
		    + 20.0*(double)p.y;
		printf("%4d  %7.4f %8.3f %7.2f %7.2f %7.2f |  %d  ", i, (double)p.y, (double)v.y,
		       (double)w.x, (double)w.y, (double)w.z, s->get_touch_count());
		if (s->get_touch_count() > 0) {
			const auto &t = s->get_touch(0);
			printf("(%7.4f,%7.4f,%7.4f)", (double)t.lever.x, (double)t.lever.y, (double)t.lever.z);
		} else printf("%25s", "-");
		printf("  %8.3f\n", E);
	}
	return 0;
}
