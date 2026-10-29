#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T=double; using V=hop::vec3<T>;
static V vec(T x,T y,T z){V v;v.set(x,y,z);return v;}
// Godot/hop-godot compute inertia from the AABB and mass: I = m/12 * (a^2+b^2).
static V box_inertia(double hx,double hy,double hz,double m){
  const double x=2*hx,y=2*hy,z=2*hz;
  return vec((T)(m*(y*y+z*z)/12),(T)(m*(x*x+z*z)/12),(T)(m*(x*x+y*y)/12));
}
static double run(bool real_tensor,double hx,double hy,double hz,V w0,int iters,double*py_out){
  auto sim=std::make_shared<hop::simulator<T>>();
  sim->set_gravity(vec(0,-20,0));
  sim->set_default_contact_mode(hop::contact_mode::speculative);
  sim->set_solver_iterations(iters);
  auto f=std::make_shared<hop::solid<T>>();
  f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
  f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-12,-1,-12),vec(12,0,12))));
  sim->add_solid(f);
  auto s=std::make_shared<hop::solid<T>>();
  s->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hx,-hy,-hz),vec(hx,hy,hz))));
  s->set_mass((T)1);
  s->set_inertia(real_tensor?box_inertia(hx,hy,hz,1.0):vec(0.005,0.09,0.09));
  s->set_position(vec(0,(T)(hy+0.05),0)); s->set_angular_velocity(w0);
  sim->add_solid(s);
  double py=-1e9;
  for(int i=0;i<600;++i){sim->update((T)(1.0/60.0)); py=std::fmax(py,(double)s->get_position().y);}
  *py_out=py;
  return (double)hop::length(s->get_angular_velocity());
}
int main(){
  printf("%-42s", "iterations:"); for(int it:{8,16,24,32,48,64}) printf("%9d",it); printf("\n");
  struct C{const char*n;bool real;double hx,hy,hz;V w;};
  C cases[]={
    {"plank .512x.1x.1  rod tensor  at rest", false,0.512,0.1,0.1,vec(0,0,0)},
    {"plank .512x.1x.1  rod tensor  spun",    false,0.512,0.1,0.1,vec(0,0,10)},
    {"plank .512x.1x.1  REAL tensor at rest", true, 0.512,0.1,0.1,vec(0,0,0)},
    {"plank .512x.1x.1  REAL tensor spun",    true, 0.512,0.1,0.1,vec(0,0,10)},
    {"gib slab .06x.01x.06 REAL     at rest", true, 0.06,0.01,0.06,vec(0,0,0)},
    {"gib slab .06x.01x.06 REAL     spun",    true, 0.06,0.01,0.06,vec(3,7,2)},
    {"gib slab .10x.015x.10 REAL    spun",    true, 0.10,0.015,0.10,vec(5,2,9)},
  };
  for(auto&c:cases){
    printf("%-42s",c.n);
    for(int it:{8,16,24,32,48,64}){double py; double w=run(c.real,c.hx,c.hy,c.hz,c.w,it,&py);
      printf("%9s", (py>c.hy+0.25)?"LAUNCH":(w>1.0?"spin":"  ok"));}
    printf("\n");
  }
  return 0;
}
