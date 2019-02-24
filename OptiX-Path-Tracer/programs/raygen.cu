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

#include "pdfs/pdf.h"
#include "prd.h"

// the 'builtin' launch index we need to render a frame
rtDeclareVariable(uint2, pixelID, rtLaunchIndex, );
rtDeclareVariable(uint2, launchDim, rtLaunchDim, );

// the ray related state
rtDeclareVariable(Ray, ray, rtCurrentRay, );
rtDeclareVariable(PerRayData, prd, rtPayload, );

rtBuffer<float3, 2> fb;  // float3 color frame buffer

rtDeclareVariable(int, samples, , );  // number of samples
rtDeclareVariable(int, frame, , );    // current frame

rtDeclareVariable(rtObject, world, , );  // scene variable

rtDeclareVariable(float3, camera_lower_left_corner, , );
rtDeclareVariable(float3, camera_horizontal, , );
rtDeclareVariable(float3, camera_vertical, , );
rtDeclareVariable(float3, camera_origin, , );
rtDeclareVariable(float3, camera_u, , );
rtDeclareVariable(float3, camera_v, , );
rtDeclareVariable(float, camera_lens_radius, , );
rtDeclareVariable(float, time0, , );
rtDeclareVariable(float, time1, , );

// Light sampling callable programs
rtDeclareVariable(int, numLights, , );
rtBuffer<float3> Light_Emissions;
rtBuffer<rtCallableProgramId<float3(PDFParams&, XorShift32&)>> Light_Sample;
rtBuffer<rtCallableProgramId<float(PDFParams&)>> Light_PDF;

// BRDF sampling callable programs
rtBuffer<rtCallableProgramId<float3(PDFParams&, XorShift32&)>> BRDF_Sample;
rtBuffer<rtCallableProgramId<float(PDFParams&)>> BRDF_PDF;
rtBuffer<rtCallableProgramId<float(PDFParams&)>> BRDF_Evaluate;

RT_FUNCTION float PowerHeuristic(unsigned int numf, float fPdf,
                                 unsigned int numg, float gPdf) {
  float f = numf * fPdf;
  float g = numg * gPdf;

  return (f * f) / (f * f + g * g);
}

RT_FUNCTION float3 Direct_Light(PerRayData& prd) {
  // return black if there's no light
  if (numLights == 0) return make_float3(0.f);

  // ramdomly pick one light and multiply the result by the number of lights
  // it's the same as dividing by the PDF if they have the same probability
  int index = ((int)((*prd.randState)() * numLights)) % numLights;

  // return black if there's just one light and we just hit it
  if (prd.matType == Diffuse_Light_Material) {
    if (numLights == 1) return make_float3(0.f);
  }

  // Sample Light
  PDFParams pdfParams(prd.origin, prd.normal);
  Light_Sample[index](pdfParams, *prd.randState);
  float lightPDF = Light_PDF[index](pdfParams);

  if (dot(pdfParams.direction, pdfParams.normal) <= 0.f)
    return make_float3(0.f);

  // Check if light is occluded
  PerRayData_Shadow prdShadow;
  Ray shadowRay = make_Ray(/* origin   : */ pdfParams.origin,
                           /* direction: */ pdfParams.direction,
                           /* ray type : */ 1,
                           /* tmin     : */ 1e-3f,
                           /* tmax     : */ RT_DEFAULT_MAX);
  rtTrace(world, shadowRay, prdShadow);

  // if light is occluded, return black
  if (prdShadow.inShadow) return make_float3(0.f);

  // Sample BRDF
  float matPDF = BRDF_PDF[prd.matType](pdfParams);
  float3 matValue = prd.attenuation * BRDF_Evaluate[prd.matType](pdfParams);

  // MIS
  float3 emission = Light_Emissions[index];
  float3 lightThroughput = matValue * prd.throughput * numLights * emission;
  lightThroughput *= PowerHeuristic(1, lightPDF, 1, matPDF);
  lightThroughput /= max(0.001f, lightPDF);

  return lightThroughput;
}

struct Camera {
  static RT_FUNCTION Ray generateRay(float s, float t, XorShift32& rnd) {
    const float3 rd = camera_lens_radius * random_in_unit_disk(rnd);
    const float3 lens_offset = camera_u * rd.x + camera_v * rd.y;
    const float3 origin = camera_origin + lens_offset;
    const float3 direction = camera_lower_left_corner + s * camera_horizontal +
                             t * camera_vertical - origin;

    return make_Ray(/* origin   : */ origin,
                    /* direction: */ direction,
                    /* ray type : */ 0,
                    /* tmin     : */ 1e-6f,
                    /* tmax     : */ RT_DEFAULT_MAX);
  }
};

RT_FUNCTION float3 color(Ray& ray, XorShift32& rnd) {
  PerRayData prd;
  prd.randState = &rnd;
  prd.time = time0 + rnd() * (time1 - time0);

  prd.throughput = make_float3(1.f);
  float3 radiance = make_float3(0.f);

  // iterative version of recursion, up to depth 50
  for (int depth = 0; depth < 50; depth++) {
    rtTrace(world, ray, prd);

    // Only sample direct light if last bounce wasn't specular
    if (!prd.isSpecular) radiance += prd.throughput * Direct_Light(prd);

    // ray got 'lost' to the environment
    // return attenuation set by miss shader
    if (prd.scatterEvent == rayMissed) {
      radiance += prd.throughput * prd.attenuation;
      break;
    }

    // ray hit a light, return emission
    else if (prd.scatterEvent == rayGotCancelled) {
      radiance += prd.throughput * prd.emitted;
      break;
    }

    // ray is still alive, and got properly bounced
    else {
      // ideal specular hit
      if (prd.isSpecular) prd.throughput *= prd.attenuation;

      // do importance sample
      else {
        PDFParams pdfParams(prd.origin, prd.normal);
        BRDF_Sample[prd.matType](pdfParams, rnd);
        float pdfValue = BRDF_PDF[prd.matType](pdfParams);

        prd.attenuation *= BRDF_Evaluate[prd.matType](pdfParams);

        prd.throughput *= prd.attenuation / pdfValue;
        prd.throughput = Clamp(prd.throughput);

        prd.origin = pdfParams.origin;
        prd.direction = pdfParams.direction;
      }

      ray = make_Ray(/* origin   : */ prd.origin,
                     /* direction: */ prd.direction,
                     /* ray type : */ 0,
                     /* tmin     : */ 1e-3f,
                     /* tmax     : */ RT_DEFAULT_MAX);
    }

    // Russian Roulette Path Termination
    float p = max_component(prd.throughput);
    if (depth > 10) {
      if (rnd() >= p)
        return prd.throughput;
      else
        prd.throughput *= 1.f / p;
    }
  }

  // recursion did not terminate - cancel it
  return radiance;
}

// Remove NaN values
RT_FUNCTION float3 de_nan(const float3& c) {
  float3 temp = c;
  if (!(temp.x == temp.x)) temp.x = 0.f;
  if (!(temp.y == temp.y)) temp.y = 0.f;
  if (!(temp.z == temp.z)) temp.z = 0.f;

  return temp;
}

RT_PROGRAM void renderPixel() {
  XorShift32 rnd;

  // initiate RNG
  unsigned int a = (pixelID.y + 1) * launchDim.x + (pixelID.x + 1);
  unsigned int b = frame + 1;

  rnd.init(a, b);

  // init frame buffer
  if (frame == 0) fb[pixelID] = make_float3(0.f);

  // Subpixel jitter: send the ray through a different position inside the
  // pixel each time, to provide antialiasing.
  float u = float(pixelID.x + rnd()) / float(launchDim.x);
  float v = float(pixelID.y + rnd()) / float(launchDim.y);

  // trace ray
  Ray ray = Camera::generateRay(u, v, rnd);

  // accumulate color
  fb[pixelID] += de_nan(color(ray, rnd));
}
