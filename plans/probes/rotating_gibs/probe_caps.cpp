#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T=double; using V=hop::vec3<T>;
static V vec(T x,T y,T z){V v;v.set(x,y,z);return v;}
static V cap_inertia(double hl,double r,double m){
  const double L=2*hl+2*r;
  return vec((T)(0.5*m*r*r),(T)(m*(3*r*r+L*L)/12),(T)(m*(3*r*r+L*L)/12));
}
int main(){
  printf("capsule manifold, hop defaults (16 solver iterations), 600 ticks\n");
  printf("%-8s %-8s %-22s %-10s %-10s %s\n","half_len","radius","initial spin","|w| end","peak y","");
  int bad=0;
  for(double hl:{0.005,0.02,0.05,0.1,0.3,0.512,0.8,1.5})
  for(double r:{0.01,0.05,0.1})
  for(int k=0;k<4;++k){
    V w0 = k==0?vec(0,0,0):k==1?vec(10,0,0):k==2?vec(0,0,10):vec(6,4,8);
    auto sim=std::make_shared<hop::simulator<T>>();
    sim->set_gravity(vec(0,-20,0));
    sim->set_default_contact_mode(hop::contact_mode::speculative);
    auto f=std::make_shared<hop::solid<T>>();
    f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
    f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-24,-1,-24),vec(24,0,24))));
    sim->add_solid(f);
    auto s=std::make_shared<hop::solid<T>>();
    s->add_shape(std::make_shared<hop::shape<T>>(hop::capsule<T>(vec(-hl,0,0),vec(2*hl,0,0),r)));
    s->set_mass((T)1); s->set_inertia(cap_inertia(hl,r,1.0));
    s->set_position(vec(0,(T)(r+0.05),0)); s->set_angular_velocity(w0);
    sim->add_solid(s);
    double py=-1e9;
    for(int i=0;i<600;++i){sim->update((T)(1.0/60.0)); py=std::fmax(py,(double)s->get_position().y);}
    const double w=(double)hop::length(s->get_angular_velocity());
    const bool launched = py > r+0.35;
    const bool spun = w > 12.0;
    if(launched||spun){
      ++bad;
      printf("%-8.3f %-8.2f %-22s %-10.3f %-10.3f %s\n",hl,r,
             k==0?"none":k==1?"about spine":k==2?"across spine":"tumbling",w,py,
             launched?"LAUNCHED":"SPUN UP");
    }
  }
  printf(bad? "%d FAILURES\n" : "all %d combinations settle\n", bad?bad:96);
  return 0;
}
