/*
 * (C) Crown copyright 2023 Met Office.
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#include "fv3jedi/Utilities/Traits.h"
#include "oops/runs/GenHybridLinearModelCoeffs.h"
#include "oops/runs/Run.h"

int main(int argc, char ** argv) {
  oops::Run run(argc, argv);
  oops::GenHybridLinearModelCoeffs<fv3jedi::Traits> genHybridLinearModelCoeffs;
  return run.execute(genHybridLinearModelCoeffs);
}