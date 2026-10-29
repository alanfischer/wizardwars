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
int main(){
  const double hx=0.090,hy=0.010,hz=0.010,m=0.2;
  auto sim=std::make_shared<hop::simulator<T>>();
  sim->set_gravity(vec(0,-G,0));
  sim->set_default_contact_mode(hop::contact_mode::speculative);
  auto f=std::make_shared<hop::solid<T>>();
  f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
  f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-60,-1,-60),vec(60,0,60))));
  sim->add_solid(f);
  auto b=std::make_shared<hop::solid<T>>();
  b->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hx,-hy,-hz),vec(hx,hy,hz))));
  const V I=aabb_inertia(hx,hy,hz,m);
  b->set_mass((T)m); b->set_inertia(I);
  b->set_position(vec(0,0.9,0)); b->set_angular_velocity(vec(9,3,5)); b->set_velocity(vec(1.2,2.0,-0.8));
  sim->add_solid(b);
  printf("rod box 18x2x2 cm. inertia = (%.2e, %.2e, %.2e)\n\n",(double)I.x,(double)I.y,(double)I.z);
  printf("%6s %9s %9s %9s %9s %9s  %s\n","frame","y","|v|","|w|","E (J)","dE","touches");
  double prevE=-1;
  for(int i=0;i<1800;++i){
    sim->update((T)(1.0/60.0));
    const V p=b->get_position(), v=b->get_velocity(), w=b->get_angular_velocity();
    hop::mat3<T> Rt; hop::transpose(Rt,b->get_orientation()); V wb; hop::mul(wb,Rt,w);
    const double E=0.5*m*((double)v.x*v.x+(double)v.y*v.y+(double)v.z*v.z)
      +0.5*((double)wb.x*wb.x*(double)I.x+(double)wb.y*wb.y*(double)I.y+(double)wb.z*wb.z*(double)I.z)
      +m*G*(double)p.y;
    const double dE = prevE<0?0:E-prevE;
    // Print the first landing, then anything that gains a lot in one frame.
    if(i>=18&&i<=30){
      printf("%6d %9.4f %9.3f %9.2f %9.4f %+9.4f  %d",i,(double)p.y,
             (double)hop::length(v),(double)hop::length(w),E,dE,b->get_touch_count());
      for(int k=0;k<b->get_touch_count();++k){
        const auto&t=b->get_touch(k);
        printf("\n           slot%d lever=(%7.4f,%7.4f,%7.4f) n=(%5.2f,%5.2f,%5.2f) sep=%+8.5f accN=%8.4f vimp=%7.3f",
          k,(double)t.lever.x,(double)t.lever.y,(double)t.lever.z,
          (double)t.normal.x,(double)t.normal.y,(double)t.normal.z,
          (double)t.separation,(double)t.accum_n,(double)t.impact_speed);
      }
      printf("\n");
    }
    prevE=E;
  }
  return 0;
}
