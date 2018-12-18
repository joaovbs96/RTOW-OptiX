#include "material.h"

/*! the implicit state's ray we will intersect against */
rtDeclareVariable(optix::Ray, ray, rtCurrentRay, );
rtDeclareVariable(float, distance, rtIntersectionDistance, );

/*! the per ray data we operate on */
rtDeclareVariable(PerRayData, prd, rtPayload, );
rtDeclareVariable(rtObject, world, , );

/*! the attributes we use to communicate between intersection programs and hit program */
rtDeclareVariable(float3, hit_rec_normal, attribute hit_rec_normal, );
rtDeclareVariable(float3, hit_rec_p, attribute hit_rec_p, );
rtDeclareVariable(float, hit_rec_u, attribute hit_rec_u, );
rtDeclareVariable(float, hit_rec_v, attribute hit_rec_v, );

/*! and finally - that particular material's parameters */
rtDeclareVariable(rtCallableProgramId<float3(float, float, float3)>, sample_texture, , );
rtDeclareVariable(float, density, , );


/*! the actual scatter function - in Pete's reference code, that's a
  virtual function, but since we have a different function per program
  we do not need this here */
inline __device__ bool scatter(const optix::Ray &ray_in,
                               DRand48 &rndState,
                               vec3f &scattered_origin,
                               vec3f &scattered_direction,
                               vec3f &attenuation) {
  // return scattering event
  scattered_origin = hit_rec_p;
  scattered_direction = random_in_unit_sphere(rndState);
  attenuation = sample_texture(hit_rec_u, hit_rec_v, hit_rec_p);
  return true;
}

inline __device__ float3 emitted(){
  return make_float3(0.f, 0.f, 0.f);
}

RT_PROGRAM void closest_hit() {
  prd.out.emitted = emitted();
  prd.out.scatterEvent
    = scatter(ray,
              *prd.in.randState,
              prd.out.scattered_origin,
              prd.out.scattered_direction,
              prd.out.attenuation)
    ? rayGotBounced
    : rayGotCancelled;
}

RT_PROGRAM void any_hit() {
    // call when rtIgnoreIntersection() when the cosntant_medium returns false
    float value = (*prd.in.randState)();
	/*float hit_distance = -(1.f / density) * log(value);

    if (hit_distance < distance)
        rtIgnoreIntersection();*/

    // density basically acts like a probability that the ray hits the geometry
	if (value > density)
		rtIgnoreIntersection();
  
    /*if (hit_distance < distance){
        rtTerminateRay(); // call closest_hit program
    }*/
}