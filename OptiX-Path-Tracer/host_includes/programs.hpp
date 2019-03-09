#ifndef PROGRAMSH
#define PROGRAMSH

#include "buffers.hpp"
#include "host_common.hpp"
#include "pdfs.hpp"
#include "textures.hpp"

#include <string>

/*! The precompiled programs code (in ptx) that our cmake script
will precompile (to ptx) and link to the generated executable */
extern "C" const char miss_program[];
extern "C" const char exception_program[];
extern "C" const char raygen_program[];

void setRayGenerationProgram(Context &g_context, BRDF_Sampler &brdf,
                             Light_Sampler &lights) {
  // create raygen program of the scene
  Program raygen = createProgram(raygen_program, "renderPixel", g_context);

  // BRDF callable program buffers
  raygen["BRDF_Sample"]->setBuffer(createBuffer(brdf.sample, g_context));
  raygen["BRDF_PDF"]->setBuffer(createBuffer(brdf.pdf, g_context));
  raygen["BRDF_Evaluate"]->setBuffer(createBuffer(brdf.eval, g_context));

  // Light sampling params and buffers
  raygen["Light_Sample"]->setBuffer(createBuffer(lights.sample, g_context));
  raygen["Light_PDF"]->setBuffer(createBuffer(lights.pdf, g_context));
  raygen["Light_Emissions"]->setBuffer(
      createBuffer(lights.emissions, g_context));
  raygen["numLights"]->setInt((int)lights.emissions.size());

  g_context->setEntryPointCount(1);
  g_context->setRayGenerationProgram(/*program ID:*/ 0, raygen);
}

typedef enum { GRADIENT, CONSTANT, IMG, HDR } Miss_Programs;

// Image Miss Programs
void setMissProgram(Context &g_context, Miss_Programs id, std::string fileName,
                    bool isSpherical = true) {
  Program missProgram;

  // LDR image background
  if (id == IMG) {
    missProgram = createProgram(miss_program, "image_background", g_context);

    Image_Texture img(fileName);
    missProgram["sample_texture"]->setProgramId(img.assignTo(g_context));
  }

  // HDR image background
  else if (id == HDR) {
    missProgram =
        createProgram(miss_program, "environmental_mapping", g_context);

    HDR_Texture img(fileName);
    missProgram["sample_texture"]->setProgramId(img.assignTo(g_context));

    // set to false if it's a cylindrical map
    missProgram["isSpherical"]->setInt(isSpherical);
  }

  else
    throw "Parameters invalid, miss program unknown or not yet implemented";

  g_context->setMissProgram(/*program ID:*/ 0, missProgram);
}

// Color Miss Programs
void setMissProgram(Context &g_context, Miss_Programs id,
                    float3 colorValue1 = make_float3(0.f),
                    float3 colorValue2 = make_float3(0.f)) {
  Program missProgram;

  // gradient pattern background
  if (id == GRADIENT) {
    missProgram = createProgram(miss_program, "gradient_color", g_context);

    Constant_Texture color1(colorValue1);
    Constant_Texture color2(colorValue2);
    missProgram["sample_color1"]->setProgramId(color1.assignTo(g_context));
    missProgram["sample_color2"]->setProgramId(color2.assignTo(g_context));
  }

  // constant color background
  else if (id == CONSTANT) {
    missProgram = createProgram(miss_program, "constant_color", g_context);

    Constant_Texture color(colorValue1);
    missProgram["sample_texture"]->setProgramId(color.assignTo(g_context));
  }

  else
    throw "Parameters invalid, miss program unknown or not yet implemented";

  g_context->setMissProgram(/*program ID:*/ 0, missProgram);
}

void setExceptionProgram(Context &g_context) {
  Program program =
      createProgram(exception_program, "exception_program", g_context);
  g_context->setExceptionProgram(/*program ID:*/ 0, program);
}

#endif