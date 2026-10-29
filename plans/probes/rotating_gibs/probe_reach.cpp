#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T=double; using V=hop::vec3<T>;
static V vec(T x,T y,T z){V v;v.set(x,y,z);return v;}
static V I3=vec(0.005,0.09,0.09);
static void run(const char*l,bool box,double hl,double r,V w0,double reach){
  auto sim=std::make_shared<hop::simulator<T>>();
  sim->set_gravity(vec(0,-20,0));
  sim->set_default_contact_mode(hop::contact_mode::speculative);
  if(reach>=0) sim->set_solver_iterations((int)reach);
  auto f=std::make_shared<hop::solid<T>>();
  f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
  f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-12,-1,-12),vec(12,0,12))));
  sim->add_solid(f);
  auto s=std::make_shared<hop::solid<T>>();
  if(box) s->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hl,-r,-r),vec(hl,r,r))));
  else    s->add_shape(std::make_shared<hop::shape<T>>(hop::capsule<T>(vec(-hl,0,0),vec(2*hl,0,0),r)));
  s->set_mass((T)1); s->set_inertia(I3);
  s->set_position(vec(0,(T)(r+0.05),0)); s->set_angular_velocity(w0);
  sim->add_solid(s);
  double py=-1e9;
  for(int i=0;i<600;++i){sim->update((T)(1.0/60.0)); py=std::fmax(py,(double)s->get_position().y);}
  printf("%-38s |w|=%8.3f peak_y=%7.3f %s\n",l,(double)hop::length(s->get_angular_velocity()),py,py>0.3?"LAUNCHED":"");
}
int main(){
  for(double reach : {-1.0, 16.0, 64.0}) {
    printf("--- solver iterations = %s ---\n", reach<0?"default":(reach<20?"16":"64"));
    run("capsule hl=0.512 spin about spine",false,0.512,0.1,vec(10,0,0),reach);
    run("capsule hl=0.800 spin about spine",false,0.800,0.1,vec(10,0,0),reach);
    run("capsule hl=0.800 at rest",         false,0.800,0.1,vec(0,0,0), reach);
    run("box hl=0.512 at rest",             true, 0.512,0.1,vec(0,0,0), reach);
    run("box hl=0.512 spin about Z",        true, 0.512,0.1,vec(0,0,10),reach);
    run("box cube 0.1 at rest",             true, 0.1,  0.1,vec(0,0,0), reach);
  }
  return 0;
}
