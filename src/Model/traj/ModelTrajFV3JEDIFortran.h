/*
 * (C) Copyright 2017 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#ifndef SRC_MODEL_TRAJ_MODELTRAJFV3JEDIFORTRAN_H_
#define SRC_MODEL_TRAJ_MODELTRAJFV3JEDIFORTRAN_H_

#include "Fortran.h"

// Forward declarations
namespace eckit {
  class Configuration;
}

namespace util {
  class DateTime;
  class Duration;
}

namespace fv3jedi {

extern "C" {

  void fv3jedi_traj_prop_f90(const F90model &,
                             const F90state &,
                             F90traj &);

  void fv3jedi_traj_minmaxrms_f90(const F90traj &,
                                  double &);

}  // extern "C"
// -----------------------------------------------------------------------------

}  // namespace fv3jedi
#endif  // SRC_MODEL_TRAJ_MODELTRAJFV3JEDIFORTRAN_H_
