// No floor. No gravity. No contacts. One body, spun, left alone.
// Rotational kinetic energy MUST be exactly constant (Euler's equations conserve it).
#include <cmath>
#include <cstdio>
#include <memory>
#include <hop/hop.h>
using T=double; using V=hop::vec3<T>;
static V vec(T x,T y,T z){V v;v.set(x,y,z);return v;}
static V aabb_inertia(double hx,double hy,double hz,double m){
  const double x=2*hx,y=2*hy,z=2*hz;
  return vec((T)(m*(y*y+z*z)/12),(T)(m*(x*x+z*z)/12),(T)(m*(x*x+y*y)/12));
}
static double spin_energy(std::shared_ptr<hop::solid<T>> b,V I){
  const V w=b->get_angular_velocity();
  hop::mat3<T> Rt; hop::transpose(Rt,b->get_orientation()); V wb; hop::mul(wb,Rt,w);
  return 0.5*((double)wb.x*wb.x*(double)I.x+(double)wb.y*wb.y*(double)I.y+(double)wb.z*wb.z*(double)I.z);
}
static void run(const char*n,double hx,double hy,double hz,V w0){
  auto sim=std::make_shared<hop::simulator<T>>();
  sim->set_gravity(vec(0,0,0));
  auto b=std::make_shared<hop::solid<T>>();
  b->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hx,-hy,-hz),vec(hx,hy,hz))));
  const V I=aabb_inertia(hx,hy,hz,0.2);
  b->set_mass((T)0.2); b->set_inertia(I);
  b->set_collide_with_scope(0);                 // collides with nothing at all
  b->set_angular_velocity(w0);
  sim->add_solid(b);
  const double E0=spin_energy(b,I);
  double Emax=E0;
  for(int i=0;i<1800;++i){ sim->update((T)(1.0/60.0)); Emax=std::fmax(Emax,spin_energy(b,I)); }
  const double E1=spin_energy(b,I);
  const double ratio = I.y/I.x;
  printf("  %-30s Ix:Iy = 1:%-6.0f  E30/E0 = %8.3fx   peak %8.3fx  %s\n",
         n,(double)ratio,E1/E0,Emax/E0,(E1/E0<1.02&&Emax/E0<1.02)?"ok":"GAINS");
}
int main(){
  printf("\nFree spin in a vacuum: no gravity, no floor, collides with nothing.\n");
  printf("Rotational energy is a conserved quantity here. Anything above 1.0 is\n");
  printf("the integrator inventing it. 30 s at 60 Hz.\n\n");
  run("cube 3x3x3, w=10",        0.015,0.015,0.015, vec(6,6,5));
  run("chunk 5x4x3, w=10",       0.025,0.020,0.015, vec(6,6,5));
  run("rod 18x2x2, w=10",        0.090,0.010,0.010, vec(6,6,5));
  run("rod 18x2x2, w=30",        0.090,0.010,0.010, vec(18,18,15));
  run("rod 18x2x2, w=60",        0.090,0.010,0.010, vec(36,36,30));
  run("shard 10x1x6, w=10",      0.050,0.005,0.030, vec(6,6,5));
  run("slab 12x3x12, w=10",      0.060,0.015,0.060, vec(6,6,5));
  run("BIG box 1m, w=10",        0.512,0.100,0.100, vec(6,6,5));
  printf("\n");
  return 0;
}
