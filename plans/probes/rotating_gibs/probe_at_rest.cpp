// Placed at rest ON the floor. v=0, w=0, no drop. Nothing to convert.
#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T=double; using V=hop::vec3<T>;
static V vec(T x,T y,T z){V v;v.set(x,y,z);return v;}
static const double G=20.0;
static V aabb_inertia(double hx,double hy,double hz,double m){
  const double x=2*hx,y=2*hy,z=2*hz;
  return vec((T)(m*(y*y+z*z)/12),(T)(m*(x*x+z*z)/12),(T)(m*(x*x+y*y)/12));
}
enum kind{BOX,CAPSULE,SPHERE};
static void run(const char*n,kind k,double hx,double hy,double hz){
  printf("  %-34s",n);
  for(int m=0;m<2;++m){
    auto sim=std::make_shared<hop::simulator<T>>();
    sim->set_gravity(vec(0,-G,0));
    sim->set_default_contact_mode(m?hop::contact_mode::speculative:hop::contact_mode::sweep_slide);
    auto f=std::make_shared<hop::solid<T>>();
    f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
    f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-60,-1,-60),vec(60,0,60))));
    sim->add_solid(f);
    auto b=std::make_shared<hop::solid<T>>();
    double rest=hy;
    if(k==BOX) b->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hx,-hy,-hz),vec(hx,hy,hz))));
    else if(k==CAPSULE) b->add_shape(std::make_shared<hop::shape<T>>(
        hop::capsule<T>(vec(-hx,0,0),vec(2*hx,0,0),(T)hy)));
    else b->add_shape(std::make_shared<hop::shape<T>>(hop::sphere<T>(vec(0,0,0),(T)hy)));
    const V I=aabb_inertia(hx,hy,hz,0.2);
    b->set_mass((T)0.2); b->set_inertia(I);
    b->set_position(vec(0,(T)rest,0));          // exactly resting
    b->set_velocity(vec(0,0,0));                 // no linear energy
    b->set_angular_velocity(vec(0,0,0));         // no spin
    sim->add_solid(b);
    double wmax=0;
    for(int i=0;i<1800;++i){ sim->update((T)(1.0/60.0));
      wmax=std::fmax(wmax,(double)hop::length(b->get_angular_velocity())); }
    const double wend=(double)hop::length(b->get_angular_velocity());
    printf(" %8.2f %8.2f %-5s", wend, wmax, (wmax<0.05)?"ok":"SPIN");
  }
  printf("\n");
}
int main(){
  printf("\nPlaced exactly at rest on a floor: v=0, w=0, no drop. 30 s.\n");
  printf("Any angular velocity at all is created from nothing.\n\n");
  printf("  %-34s %-23s %-23s\n","","      sweep_slide","      speculative");
  printf("  %-34s %8s %8s %-5s %8s %8s %-5s\n","","w end","w max","","w end","w max","");
  printf("  %s\n","-------------------------------------------------------------------------------------");
  run("sphere r=1.5cm",              SPHERE, 0.015,0.015,0.015);
  run("cube 3x3x3 cm",               BOX,    0.015,0.015,0.015);
  run("chunk 5x4x3 cm",              BOX,    0.025,0.020,0.015);
  run("rod BOX 18x2x2 cm (bone)",    BOX,    0.090,0.010,0.010);
  run("rod CAPSULE 18cm r=1cm",      CAPSULE,0.090,0.010,0.010);
  run("shard BOX 10x1x6 cm",         BOX,    0.050,0.005,0.030);
  run("slab BOX 12x3x12 cm (today)", BOX,    0.060,0.015,0.060);
  run("BIG capsule 1m r=10cm",       CAPSULE,0.512,0.100,0.100);
  run("BIG box 1m x 20 x 20 cm",     BOX,    0.512,0.100,0.100);
  printf("\n");
  return 0;
}
