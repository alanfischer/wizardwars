// Real gib parameters against a real BSP hull floor.
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <memory>
#include <vector>
#include <hop/hop.h>
#include "hop_bsp_traceable.h"
using T = double; using V = hop::vec3<T>;
using namespace hop_bsp;
#include "bsp_fixtures.h"

static V cap_inertia(double hl,double r,double m){
  const double L=2*hl+2*r;
  return vec((T)(0.5*m*r*r),(T)(m*(3*r*r+L*L)/12),(T)(m*(3*r*r+L*L)/12));
}
int main(){
  auto blob = make_floor_map();
  printf("gib-scale capsules on a BSP hull floor, hop defaults\n");
  printf("%-9s %-7s %-14s %-9s %-9s %-9s\n","half_len","radius","launch spin","|w| end","rest y","peak y");
  int bad=0, n=0;
  for(double hl:{0.02,0.04,0.06,0.09,0.12})
  for(double r:{0.008,0.015,0.03})
  for(int k=0;k<3;++k){
    ++n;
    auto sim=std::make_shared<hop::simulator<T>>();
    sim->set_gravity(vec(0,-20,0));
    sim->set_default_contact_mode(hop::contact_mode::speculative);
    auto tr=std::make_unique<HopBspTraceable<T>>();
    assert(tr->build(blob.data(),blob.size(),0,(T)SCALE,hopbsp::BLOCK_SOLID));
    auto world=std::make_shared<hop::solid<T>>();
    world->set_infinite_mass(); world->set_coefficient_of_gravity(T{});
    world->add_shape(std::make_shared<hop::shape<T>>(std::move(tr)));
    sim->add_solid(world);

    auto s=std::make_shared<hop::solid<T>>();
    s->add_shape(std::make_shared<hop::shape<T>>(hop::capsule<T>(vec(-hl,0,0),vec(2*hl,0,0),(T)r)));
    s->set_mass((T)0.2); s->set_inertia(cap_inertia(hl,r,0.2));
    s->set_position(vec(0,0.9,0));
    // A gib launch: tumbling hard, thrown sideways.
    V w0 = k==0?vec(9,3,5):k==1?vec(2,11,4):vec(6,6,12);
    s->set_angular_velocity(w0);
    s->set_velocity(vec(1.2,2.0,-0.8));
    sim->add_solid(s);

    double py=-1e9;
    for(int i=0;i<900;++i){sim->update((T)(1.0/60.0)); py=std::fmax(py,(double)s->get_position().y);}
    const double w=(double)hop::length(s->get_angular_velocity());
    const double y=(double)s->get_position().y;
    const bool fail = (w>1.0) || (py>1.2) || !(y>-0.01 && y<hl+r+0.05);
    if(fail){++bad;
      printf("%-9.3f %-7.3f %-14s %-9.3f %-9.4f %-9.3f FAIL\n",hl,r,
             k==0?"tumble A":k==1?"tumble B":"tumble C",w,y,py);}
  }
  if(!bad) printf("all %d gib configurations come to rest\n",n);
  else printf("%d of %d FAILED\n",bad,n);
  return 0;
}
