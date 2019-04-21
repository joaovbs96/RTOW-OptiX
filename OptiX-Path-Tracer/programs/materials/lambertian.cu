// ======================================================================== //
// Copyright 2018 Ingo Wald                                                 //
//                                                                          //
// Licensed under the Apache License, Version 2.0 (the "License");          //
// you may not use this file except in compliance with the License.         //
// You may obtain a copy of the License at                                  //
//                                                                          //
//     http://www.apache.org/licenses/LICENSE-2.0                           //
//                                                                          //
// Unless required by applicable law or agreed to in writing, software      //
// distributed under the License is distributed on an "AS IS" BASIS,        //
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. //
// See the License for the specific language governing permissions and      //
// limitations under the License.                                           //
// ======================================================================== //

#include "material.cuh"

/*! the implicit state's ray we will intersect against */
rtDeclareVariable(Ray, ray, rtCurrentRay, );

/*! the per ray data we operate on */
rtDeclareVariable(PerRayData, prd, rtPayload, );
rtDeclareVariable(rtObject, world, , );

/*! the attributes we use to communicate between intersection programs and hit
 * program */
rtDeclareVariable(HitRecord, hit_rec, attribute hit_rec, );

/*! and finally - that particular material's parameters */
rtDeclareVariable(rtCallableProgramId<float3(float, float, float3, int)>,
                  sample_texture, , );

RT_PROGRAM void closest_hit() {
  // get material params from buffer
  int texIndex = hit_rec.index;

  // assign material params to prd
  prd.matType = Lambertian_BRDF;
  prd.isSpecular = false;
  prd.scatterEvent = rayGotBounced;

  float3 color = sample_texture(hit_rec.u, hit_rec.v, hit_rec.p, texIndex);
  prd.matParams.attenuation = color;

  // assign hit params to prd
  prd.origin = hit_rec.p;
  prd.geometric_normal = hit_rec.geometric_normal;
  prd.shading_normal = hit_rec.shading_normal;
}

RT_CALLABLE_PROGRAM float3 BRDF_Sample(const BRDFParameters &surface,
                                       const float3 &P,   // next ray origin
                                       const float3 &Wo,  // prev ray direction
                                       const float3 &N,   // shading normal
                                       uint &seed) {
  float3 Wi;
  cosine_sample_hemisphere(rnd(seed), rnd(seed), Wi);

  Onb uvw(N);
  uvw.inverse_transform(Wi);

  return Wi;
}

RT_CALLABLE_PROGRAM float BRDF_PDF(const BRDFParameters &surface,
                                   const float3 &P,    // next ray origin
                                   const float3 &Wo,   // prev ray direction
                                   const float3 &Wi,   // next ray direction
                                   const float3 &N) {  // shading normal
  float cosine = dot(normalize(Wi), normalize(N));

  if (cosine < 0.f)
    return 0.f;
  else
    return cosine / PI_F;
}

RT_CALLABLE_PROGRAM float3
BRDF_Evaluate(const BRDFParameters &surface,
              const float3 &P,    // next ray origin
              const float3 &Wo,   // prev ray direction
              const float3 &Wi,   // next ray direction
              const float3 &N) {  // shading normal
  float cosine = dot(normalize(Wi), normalize(N));

  if (cosine < 0.f)
    return make_float3(0.f);
  else
    return (cosine * surface.attenuation) / PI_F;
}