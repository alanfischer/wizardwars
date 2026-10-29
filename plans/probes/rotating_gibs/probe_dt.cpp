#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T = double; using V = hop::vec3<T>;
static V vec(T x,T y,T z){V v;v.set(x,y,z);return v;}
int main(){
  printf("%-8s %-6s %-10s %-10s\n","dt(ms)","steps","|w| @5s","peak y");
  for (double dtms : {16.667, 8.333, 4.167, 2.083, 1.0}) {
    auto sim=std::make_shared<hop::simulator<T>>();
    sim->set_gravity(vec(0,-20,0));
    sim->set_default_contact_mode(hop::contact_mode::speculative);
    auto f=std::make_shared<hop::solid<T>>();
    f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
    f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-12,-1,-12),vec(12,0,12))));
    sim->add_solid(f);
    auto s=std::make_shared<hop::solid<T>>();
    s->add_shape(std::make_shared<hop::shape<T>>(hop::capsule<T>(vec(-0.512,0,0),vec(1.024,0,0),0.1)));
    s->set_mass((T)1); s->set_inertia(vec(0.005,0.09,0.09));
    s->set_position(vec(0,0.15,0)); s->set_angular_velocity(vec(10,0,0));
    sim->add_solid(s);
    const double dt=dtms/1000.0; const int n=(int)(5.0/dt);
    double py=-1e9;
    for(int i=0;i<n;++i){ sim->update((T)dt); py=std::fmax(py,(double)s->get_position().y); }
    printf("%-8.3f %-6d %-10.3f %-10.3f\n",dtms,n,(double)hop::length(s->get_angular_velocity()),py);
  }
  return 0;
}
