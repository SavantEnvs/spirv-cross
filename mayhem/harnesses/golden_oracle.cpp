// golden_oracle.cpp — self-contained PATCH-grade functional oracle for SPIRV-Cross.
//
// SPIRV-Cross's upstream test driver (test_shaders.py / test_shaders.sh) needs external
// glslang + spirv-tools to (re)compile the shader corpus, so it is NOT self-contained. This
// oracle instead exercises the SHIPPED cross-compiler on a known-good SPIR-V module that lives
// in the repo (tests-other/c_api_test.spv), with no external toolchain:
//
//   1. Read the .spv module (path = argv[1]); assert it carries the SPIR-V magic 0x07230203.
//   2. Parse it (spirv_cross::Parser) and assert the parsed IR is non-trivial (has the entry
//      point / a function).
//   3. Cross-compile the SAME module to GLSL and to MSL and assert both emit non-empty source
//      that contains the expected "main" entry point. This asserts real END-TO-END behaviour:
//      a no-op / "return success" patch of the parser or the compilers cannot produce valid
//      GLSL/MSL text, so it cannot pass.
//   4. Negative case: corrupt the module's bound/header words and assert the parser REJECTS it
//      (throws). A patch that makes the parser accept arbitrary garbage fails this check.
//
// Exit 0 iff every assertion holds. Built with the project's own static libs by mayhem/build.sh.

#include "spirv_glsl.hpp"
#include "spirv_msl.hpp"
#include "spirv_parser.hpp"
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace spirv_cross;

static std::vector<uint32_t> read_spirv(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "oracle: cannot open %s\n", path);
    return {};
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  std::vector<uint32_t> words;
  if (n > 0 && (n % 4) == 0) {
    words.resize((size_t)n / 4);
    if (fread(words.data(), 1, (size_t)n, f) != (size_t)n)
      words.clear();
  }
  fclose(f);
  return words;
}

static int fail(const char *msg) {
  fprintf(stderr, "oracle FAIL: %s\n", msg);
  return 1;
}

int main(int argc, char **argv) {
  if (argc != 2)
    return fail("usage: golden_oracle <module.spv>");

  std::vector<uint32_t> spirv = read_spirv(argv[1]);
  if (spirv.size() < 5)
    return fail("module too small / unreadable");
  if (spirv[0] != 0x07230203u)
    return fail("missing SPIR-V magic 0x07230203");

  // ---- 1) parse the good module ----
  ParsedIR parsed_ir;
  try {
    Parser parser(spirv);
    parser.parse();
    parsed_ir = std::move(parser.get_parsed_ir());
  } catch (const std::exception &e) {
    fprintf(stderr, "parse threw: %s\n", e.what());
    return fail("parser rejected a known-good module");
  }
  if (parsed_ir.ids.empty())
    return fail("parsed IR has no ids");

  // ---- 2) cross-compile to GLSL ----
  std::string glsl;
  try {
    CompilerGLSL comp(parsed_ir);
    // Modules that use separate image+sampler objects (Vulkan-style) must have the combined
    // image samplers remapped before they can be emitted as GLSL (which has no separate samplers).
    comp.build_combined_image_samplers();
    glsl = comp.compile();
  } catch (const std::exception &e) {
    fprintf(stderr, "GLSL compile threw: %s\n", e.what());
    return fail("GLSL cross-compile failed on a known-good module");
  }
  if (glsl.empty() || glsl.find("void main()") == std::string::npos)
    return fail("GLSL output missing 'void main()'");

  // ---- 3) cross-compile to MSL (fresh parse: compilers consume the IR) ----
  std::string msl;
  try {
    Parser parser2(spirv);
    parser2.parse();
    CompilerMSL comp(std::move(parser2.get_parsed_ir()));
    msl = comp.compile();
  } catch (const std::exception &e) {
    fprintf(stderr, "MSL compile threw: %s\n", e.what());
    return fail("MSL cross-compile failed on a known-good module");
  }
  if (msl.empty() || msl.find("main") == std::string::npos)
    return fail("MSL output missing 'main'");

  // ---- 4) negative: a corrupted module must be rejected ----
  // Smash the ID bound (header word 3) to a huge value and scribble the instruction stream;
  // the parser must throw rather than silently accept it.
  {
    std::vector<uint32_t> bad = spirv;
    bad[3] = 0xFFFFFFFFu; // absurd ID bound
    for (size_t i = 5; i < bad.size(); i++)
      bad[i] ^= 0xDEADBEEFu;
    bool threw = false;
    try {
      Parser parser_bad(bad);
      parser_bad.parse();
    } catch (...) {
      threw = true;
    }
    if (!threw)
      return fail("parser accepted a corrupted module (should have thrown)");
  }

  printf("oracle OK: parsed + emitted GLSL(%zu) + MSL(%zu); corrupted module rejected\n",
         glsl.size(), msl.size());
  return 0;
}
