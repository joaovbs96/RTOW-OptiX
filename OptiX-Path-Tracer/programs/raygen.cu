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

#include "pdfs/pdf.cuh"
#include "prd.cuh"

// launch index and frame dimensions
rtDeclareVariable(uint2, pixelID, rtLaunchIndex, );
rtDeclareVariable(uint2, launchDim, rtLaunchDim, );

// ray related state
rtDeclareVariable(Ray, ray, rtCurrentRay, );
rtDeclareVariable(PerRayData, prd, rtPayload, );

rtBuffer<float4, 2> acc_buffer;      // HDR color frame buffer
rtBuffer<uchar4, 2> display_buffer;  // display buffer

rtDeclareVariable(int, samples, , );    // number of samples
rtDeclareVariable(int, frame, , );      // frame number
rtDeclareVariable(int2, pixelDim, , );  // pxiel dimension for stratification

rtDeclareVariable(rtObject, world, , );  // scene/top obj variable

// Camera parameters
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
rtBuffer<rtCallableProgramId<float3(PDFParams&, uint&)>> Light_Sample;
rtBuffer<rtCallableProgramId<float(PDFParams&)>> Light_PDF;

// BRDF sampling callable programs
rtBuffer<rtCallableProgramId<float3(PDFParams&, uint&)>> BRDF_Sample;
rtBuffer<rtCallableProgramId<float(PDFParams&)>> BRDF_PDF;
rtBuffer<rtCallableProgramId<float(PDFParams&)>> BRDF_Evaluate;

RT_FUNCTION float PowerHeuristic(unsigned int numf, float fPdf,
                                 unsigned int numg, float gPdf) {
  float f = numf * fPdf;
  float g = numg * gPdf;

  return (f * f) / (f * f + g * g);
}

RT_FUNCTION float3 Direct_Light(PerRayData& prd) {
  float3 directLight = make_float3(0.f);

  // return black if there's no light
  if (numLights == 0) return make_float3(0.f);

  // ramdomly pick one light and multiply the result by the number of lights
  // it's the same as dividing by the PDF if they have the same probability
  int index = ((int)(rnd(prd.seed) * numLights)) % numLights;

  // return black if there's just one light and we just hit it
  if (prd.matType == Diffuse_Light_Material) {
    if (numLights == 1) return make_float3(0.f);
  }

  // Sample Light
  float3 emission = Light_Emissions[index];
  PDFParams pdfParams(prd.origin, prd.normal);
  Light_Sample[index](pdfParams, prd.seed);
  float lightPDF = Light_PDF[index](pdfParams);

  // only sample if surface normal is in the light direction
  if (dot(pdfParams.direction, pdfParams.normal) < 0.f) return make_float3(0.f);

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

  // multiple importance sample

  // Sample light
  if (lightPDF != 0.f && !isNull(emission)) {
    float matPDF = BRDF_PDF[prd.matType](pdfParams);
    float3 matValue = prd.attenuation * BRDF_Evaluate[prd.matType](pdfParams);
    if (lightPDF != 0.f && !isNull(emission)) {
      float weight = PowerHeuristic(1, lightPDF, 1, matPDF);
      directLight += matValue * emission * weight / lightPDF;
    }
  }

  // Sample BRDF
  BRDF_Sample[prd.matType](pdfParams, prd.seed);
  float matPDF = BRDF_PDF[prd.matType](pdfParams);
  float3 matValue = prd.attenuation * BRDF_Evaluate[prd.matType](pdfParams);
  if (matPDF != 0.f && !isNull(matValue)) {
    lightPDF = Light_PDF[index](pdfParams);

    // we didn't hit anything, ignore BRDF sample
    if (!lightPDF) return directLight;

    float weight = PowerHeuristic(1, matPDF, 1, lightPDF);
    directLight += matValue * emission * weight / matPDF;
  }

  return directLight;
}

struct Camera {
  static RT_FUNCTION Ray generateRay(float s, float t, uint& seed) {
    const float3 rd = camera_lens_radius * random_in_unit_disk(seed);
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

RT_FUNCTION float3 color(Ray& ray, uint& seed) {
  PerRayData prd;
  prd.seed = seed;
  prd.time = time0 + rnd(prd.seed) * (time1 - time0);

  prd.throughput = make_float3(1.f);
  float3 radiance = make_float3(0.f);

  // iterative version of recursion, up to depth 50
  for (int depth = 0; depth < 50; depth++) {
    rtTrace(world, ray, prd);  // Trace a new ray

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
      if (prd.isSpecular)
        prd.throughput *= prd.attenuation;

      else {
        PDFParams pdfParams(prd.origin, prd.normal);
        BRDF_Sample[prd.matType](pdfParams, seed);
        float pdfValue = BRDF_PDF[prd.matType](pdfParams);

        // Evaluate BRDF
        prd.attenuation *= BRDF_Evaluate[prd.matType](pdfParams);

        // Accumulate color
        prd.throughput *= prd.attenuation / pdfValue;

        // Update ray origin and direction
        prd.origin = pdfParams.origin;
        prd.direction = pdfParams.direction;
      }

      // generate a new ray
      ray = make_Ray(/* origin   : */ prd.origin,
                     /* direction: */ prd.direction,
                     /* ray type : */ 0,
                     /* tmin     : */ 1e-3f,
                     /* tmax     : */ RT_DEFAULT_MAX);
    }

    // Russian Roulette Path Termination
    float p = max_component(prd.throughput);
    if (depth > 10) {
      if (rnd(prd.seed) >= p)
        return radiance + prd.throughput * prd.attenuation;
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

/*RT_FUNCTION uchar4 make_Color(float4 col, int2 pixelDim) {
  float3 temp = make_float3(col.x, col.y, col.z) / (2 * (frame + 1));
  temp = sqrt(temp / (pixelDim.x * pixelDim.y));

  int r = int(255.99 * Clamp(temp.x, 0.f, 1.f));  // R
  int g = int(255.99 * Clamp(temp.y, 0.f, 1.f));  // G
  int b = int(255.99 * Clamp(temp.z, 0.f, 1.f));  // B
  int a = int(255.99 * Clamp(1.f, 0.f, 1.f));     // A

  return make_uchar4(r, g, b, a);
}

RT_PROGRAM void renderPixel() {
  // get RNG seed
  uint seed = tea<16>(launchDim.x * pixelID.y + pixelID.x, frame + 1);

  // initialize acc buffer if needed
  uint2 index = make_uint2(pixelID.x, launchDim.y - pixelID.y - 1);
  if (frame == 0) acc_buffer[index] = make_float4(0.f);

  // stratification: run once for each strata
  for (int i = 0; i < pixelDim.x; i++) {
    for (int j = 0; j < pixelDim.y; j++) {
      // Subpixel jitter: send the ray through a different position inside the
      // pixel each time, to provide antialiasing.
      float u = float(pixelID.x + ((i + rnd(seed)) / pixelDim.x)) / launchDim.x;
      float v = float(pixelID.y + ((j + rnd(seed)) / pixelDim.y)) / launchDim.y;

      // trace ray
      Ray ray = Camera::generateRay(u, v, seed);

      // accumulate color
      float3 col = de_nan(color(ray, seed));
      acc_buffer[index] += make_float4(col.x, col.y, col.z, 1.f);
    }
  }

  display_buffer[index] = make_Color(acc_buffer[index], pixelDim);
}*/

RT_FUNCTION uchar4 make_Color(float4 col) {
  float3 temp = sqrt(make_float3(col.x, col.y, col.z) / (frame + 1));

  int r = int(255.99 * Clamp(temp.x, 0.f, 1.f));  // R
  int g = int(255.99 * Clamp(temp.y, 0.f, 1.f));  // G
  int b = int(255.99 * Clamp(temp.z, 0.f, 1.f));  // B
  int a = int(255.99 * Clamp(1.f, 0.f, 1.f));     // A

  return make_uchar4(r, g, b, a);
}

// TODO: test rng from cudapt
// https://
// github.com/straaljager/GPU-path-tracing-tutorial-1/blob/master/smallptCUDA.cu

RT_PROGRAM void renderPixel() {
  // get RNG seed
  uint seed = tea<64>(launchDim.x * pixelID.y + pixelID.x, frame);

  // initialize acc buffer if needed
  uint2 index = make_uint2(pixelID.x, launchDim.y - pixelID.y - 1);
  if (frame == 0) acc_buffer[index] = make_float4(0.f);

  // Subpixel jitter: send the ray through a different position inside the
  // pixel each time, to provide antialiasing.
  float u = float(pixelID.x + rnd(seed)) / float(launchDim.x);
  float v = float(pixelID.y + rnd(seed)) / float(launchDim.y);

  // trace ray
  Ray ray = Camera::generateRay(u, v, seed);

  // accumulate color
  float3 col = de_nan(color(ray, seed));
  acc_buffer[index] += make_float4(col.x, col.y, col.z, 1.f);
  display_buffer[index] = make_Color(acc_buffer[index]);
}