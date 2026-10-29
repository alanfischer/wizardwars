// Which mechanism makes a thin tumbling box gain energy? Turn things off one at a time.
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
static double energy(std::shared_ptr<hop::solid<T>> b,V I){
  const V v=b->get_velocity(), w=b->get_angular_velocity();
  hop::mat3<T> Rt; hop::transpose(Rt,b->get_orientation()); V wb; hop::mul(wb,Rt,w);
  return 0.5*(double)b->get_mass()*((double)v.x*v.x+(double)v.y*v.y+(double)v.z*v.z)
       + 0.5*((double)wb.x*wb.x*(double)I.x+(double)wb.y*wb.y*(double)I.y+(double)wb.z*wb.z*(double)I.z)
       + (double)b->get_mass()*G*(double)b->get_position().y;
}
struct opt{ double rest=-1; double margin=-1; double angcap=-1; int positers=-1;
            double fric=-1; int veliters=-1; bool nogravrot=false; };
static double growth(V spin,opt o){
  auto sim=std::make_shared<hop::simulator<T>>();
  sim->set_gravity(vec(0,-G,0));
  sim->set_default_contact_mode(hop::contact_mode::speculative);
  if(o.margin>=0)   sim->set_speculative_margin((T)o.margin);
  if(o.positers>=0) sim->set_position_iterations(o.positers);
  if(o.veliters>0)  sim->set_solver_iterations(o.veliters);
  if(o.angcap>=0)   sim->set_max_angular_velocity_component((T)o.angcap);
  auto f=std::make_shared<hop::solid<T>>();
  f->set_infinite_mass(); f->set_coefficient_of_gravity(T{});
  if(o.rest>=0) f->set_coefficient_of_restitution((T)o.rest);
  f->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-60,-1,-60),vec(60,0,60))));
  sim->add_solid(f);
  const double hx=0.090,hy=0.010,hz=0.010;
  auto b=std::make_shared<hop::solid<T>>();
  b->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hx,-hy,-hz),vec(hx,hy,hz))));
  const V I=aabb_inertia(hx,hy,hz,0.2);
  b->set_mass((T)0.2); b->set_inertia(I);
  if(o.rest>=0){ b->set_coefficient_of_restitution((T)o.rest);
                 b->set_restitution_combine(hop::restitution_combine::minimum); }
  if(o.fric>=0){ b->set_coefficient_of_static_friction((T)o.fric);
                 b->set_coefficient_of_dynamic_friction((T)o.fric); }
  b->set_position(vec(0,0.9,0)); b->set_angular_velocity(spin); b->set_velocity(vec(1.2,2.0,-0.8));
  sim->add_solid(b);
  double E5=0;
  for(int i=0;i<1800;++i){ sim->update((T)(1.0/60.0)); if(i==300) E5=energy(b,I); }
  const double E30=energy(b,I);
  return (E5>1e-9)? E30/E5 : 999.0;
}
static void row(const char*n,opt o){
  V spins[3]={vec(9,3,5),vec(2,11,4),vec(6,6,12)};
  double worst=0; for(int k=0;k<3;++k) worst=std::fmax(worst,growth(spins[k],o));
  printf("  %-44s %14.2fx %s\n",n,worst,worst<=1.05?"ok":"");
}
int main(){
  printf("\nrod box 18x2x2 cm, tumbling, speculative. E30/E5, worst of 3 launches.\n");
  printf("Its half-thickness is 10 mm; hop's speculative margin defaults to 8 mm.\n\n");
  row("baseline (all defaults)", opt{});
  row("restitution 0", [](){opt o; o.rest=0; return o;}());
  row("friction 0", [](){opt o; o.fric=0; return o;}());
  row("position iterations 0 (no NGS push-out)", [](){opt o; o.positers=0; return o;}());
  row("position iterations 32", [](){opt o; o.positers=32; return o;}());
  row("solver iterations 64", [](){opt o; o.veliters=64; return o;}());
  row("angular cap 5 rad/s", [](){opt o; o.angcap=5; return o;}());
  printf("\n  speculative margin (default 8 mm, body half-thickness 10 mm):\n");
  for(double mm:{8.0,4.0,2.0,1.0,0.5}){
    char buf[64]; snprintf(buf,sizeof buf,"  margin %.1f mm",mm);
    opt o; o.margin=mm/1000.0; row(buf,o);
  }
  printf("\n");
  return 0;
}
