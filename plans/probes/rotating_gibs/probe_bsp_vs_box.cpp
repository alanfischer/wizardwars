// Is the BSP traceable implicated in either bug? Same bodies, two floors.
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <memory>
#include <vector>
#include <hop/hop.h>
#include "hop_bsp_traceable.h"
using T=double; using V=hop::vec3<T>;
using namespace hop_bsp;
#include "bsp_fixtures.h"
static const double G=20.0, M=0.2;
static V aabb_inertia(double hx,double hy,double hz,double m){
  const double x=2*hx,y=2*hy,z=2*hz;
  return vec((T)(m*(y*y+z*z)/12),(T)(m*(x*x+z*z)/12),(T)(m*(x*x+y*y)/12));
}
static double E(std::shared_ptr<hop::solid<T>> b,V I){
  const V v=b->get_velocity();
  hop::mat3<T> Rt; hop::transpose(Rt,b->get_orientation()); V wb; hop::mul(wb,Rt,b->get_angular_velocity());
  return 0.5*M*((double)v.x*v.x+(double)v.y*v.y+(double)v.z*v.z)
    +0.5*((double)wb.x*wb.x*(double)I.x+(double)wb.y*wb.y*(double)I.y+(double)wb.z*wb.z*(double)I.z)
    +M*G*(double)b->get_position().y;
}
static double land(bool bsp,std::vector<uint8_t>&blob,double hx,double hy,double hz,V spin,hop::contact_mode mode){
  auto sim=std::make_shared<hop::simulator<T>>();
  sim->set_gravity(vec(0,-G,0)); sim->set_default_contact_mode(mode);
  auto w=std::make_shared<hop::solid<T>>();
  w->set_infinite_mass(); w->set_coefficient_of_gravity(T{});
  if(bsp){auto tr=std::make_unique<HopBspTraceable<T>>();
    assert(tr->build(blob.data(),blob.size(),0,(T)SCALE,hopbsp::BLOCK_SOLID));
    w->add_shape(std::make_shared<hop::shape<T>>(std::move(tr)));}
  else w->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-60,-1,-60),vec(60,0,60))));
  sim->add_solid(w);
  auto b=std::make_shared<hop::solid<T>>();
  b->add_shape(std::make_shared<hop::shape<T>>(hop::aa_box<T>(vec(-hx,-hy,-hz),vec(hx,hy,hz))));
  const V I=aabb_inertia(hx,hy,hz,M);
  b->set_mass((T)M); b->set_inertia(I);
  b->set_position(vec(0,0.9,0)); b->set_angular_velocity(spin); b->set_velocity(vec(1.2,2.0,-0.8));
  sim->add_solid(b);
  double E5=0;
  for(int i=0;i<1800;++i){ sim->update((T)(1.0/60.0)); if(i==300) E5=E(b,I); }
  return E5>1e-9? E(b,I)/E5 : 999.0;
}
int main(){
  auto blob=make_floor_map();
  struct C{const char*n;double hx,hy,hz;};
  C cs[]={{"cube  3x3x3",0.015,0.015,0.015},{"chunk 5x4x3",0.025,0.020,0.015},
          {"slab 12x3x12",0.060,0.015,0.060},{"rod  18x2x2",0.090,0.010,0.010}};
  V spins[3]={vec(9,3,5),vec(2,11,4),vec(6,6,12)};
#ifdef HOP_PROBE_ENERGY_PROJECT
  printf("\n[integrator FIXED]  ");
#else
  printf("\n[stock hop]  ");
#endif
  printf("E30/E5, worst of 3 launches\n\n");
  printf("  %-14s %-22s %-22s\n","","      plain aa_box floor","      BSP hull floor");
  printf("  %-14s %10s %10s %10s %10s\n","","slide","specul.","slide","specul.");
  printf("  %s\n","--------------------------------------------------------------");
  for(auto&c:cs){
    printf("  %-14s",c.n);
    for(int bsp=0;bsp<2;++bsp) for(int m=0;m<2;++m){
      const auto mode=m?hop::contact_mode::speculative:hop::contact_mode::sweep_slide;
      double worst=0; for(int k=0;k<3;++k) worst=std::fmax(worst,land(bsp,blob,c.hx,c.hy,c.hz,spins[k],mode));
      printf(" %9.2fx",worst);
    }
    printf("\n");
  }
  printf("\n");
  return 0;
}
