#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T = double; using V = hop::vec3<T>;
static V vec(T x, T y, T z) { V v; v.set(x,y,z); return v; }
static V I3 = vec(0.005, 0.09, 0.09);

static std::shared_ptr<hop::simulator<T>> floor_sim() {
	auto sim = std::make_shared<hop::simulator<T>>();
	sim->set_gravity(vec(0,-20,0));
	sim->set_default_contact_mode(hop::contact_mode::speculative);
	auto f = std::make_shared<hop::solid<T>>();
	f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
	f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-12,-1,-12), vec(12,0,12))));
	sim->add_solid(f);
	return sim;
}
static double run(T half_len, T radius, V w0, double mu, double *peak_y) {
	auto sim = floor_sim();
	auto s = std::make_shared<hop::solid<T>>();
	s->add_shape(std::make_shared<hop::shape<T>>(
	    hop::capsule<T>(vec(-half_len,0,0), vec(2*half_len,0,0), radius)));
	s->set_mass((T)1); s->set_inertia(I3);
	if (mu >= 0) { s->set_coefficient_of_static_friction((T)mu); s->set_coefficient_of_dynamic_friction((T)mu); }
	s->set_position(vec(0, (T)(radius + 0.05), 0));
	s->set_angular_velocity(w0);
	sim->add_solid(s);
	double py = -1e9;
	for (int i = 0; i < 600; ++i) {
		sim->update((T)(1.0/60.0));
		py = std::fmax(py, (double)s->get_position().y);
	}
	*peak_y = py;
	return (double)hop::length(s->get_angular_velocity());
}
int main() {
	printf("radius fixed 0.1, spin 10 rad/s ABOUT the spine (x), default friction\n");
	printf("%-10s %-10s %-10s %s\n", "half_len", "|w| @600", "peak y", "verdict");
	for (double L : {0.0, 0.001, 0.01, 0.05, 0.1, 0.2, 0.3, 0.512, 0.8}) {
		double py; double w = run((T)L, 0.1, vec(10,0,0), -1, &py);
		printf("%-10.3f %-10.3f %-10.3f %s\n", L, w, py, (py > 0.3 ? "LAUNCHED" : (w > 12 ? "spun up" : "")));
	}
	printf("\nspine 0.512, radius 0.1, spin about spine — friction sweep\n");
	printf("%-10s %-10s %-10s\n", "mu", "|w| @600", "peak y");
	for (double mu : {0.0, 0.1, 0.25, 0.5, 1.0, 2.0}) {
		double py; double w = run(0.512, 0.1, vec(10,0,0), mu, &py);
		printf("%-10.2f %-10.3f %-10.3f\n", mu, w, py);
	}
	printf("\nspine 0.512, radius 0.1, mu default — initial spin sweep about spine\n");
	printf("%-10s %-10s %-10s\n", "|w0|", "|w| @600", "peak y");
	for (double w0 : {0.0, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0}) {
		double py; double w = run(0.512, 0.1, vec((T)w0,0,0), -1, &py);
		printf("%-10.2f %-10.3f %-10.3f\n", w0, w, py);
	}
	return 0;
}
