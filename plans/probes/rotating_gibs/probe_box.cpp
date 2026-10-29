#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T=double; using V=hop::vec3<T>;
static V vec(T x,T y,T z){V v;v.set(x,y,z);return v;}
int main(){
  auto sim=std::make_shared<hop::simulator<T>>();
  sim->set_gravity(vec(0,-20,0));
  sim->set_default_contact_mode(hop::contact_mode::speculative);
  auto f=std::make_shared<hop::solid<T>>();
  f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
  f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-12,-1,-12),vec(12,0,12))));
  sim->add_solid(f);
  auto s=std::make_shared<hop::solid<T>>();
  s->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-0.512,-0.1,-0.1),vec(0.512,0.1,0.1))));
  s->set_mass((T)1); s->set_inertia(vec(0.005,0.09,0.09));
  s->set_position(vec(0,0.15,0)); s->set_angular_velocity(vec(0,0,10));
  sim->add_solid(s);
  printf("frame     y       vy       wz    touches  levers\n");
  for(int i=0;i<14;++i){
    sim->update((T)(1.0/60.0));
    printf("%4d %8.3f %9.2f %8.2f   %d   ",i,(double)s->get_position().y,
           (double)s->get_velocity().y,(double)s->get_angular_velocity().z,s->get_touch_count());
    for(int k=0;k<s->get_touch_count();++k){
      const auto &t=s->get_touch(k);
      printf("(%6.3f,%6.3f,%6.3f) ",(double)t.lever.x,(double)t.lever.y,(double)t.lever.z);
    }
    printf("\n");
  }
  return 0;
}
