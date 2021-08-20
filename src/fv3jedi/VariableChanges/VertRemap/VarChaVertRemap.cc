/*
 * (C) Copyright 2017-2020  UCAR.
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#include <ostream>
#include <string>

#include "eckit/config/Configuration.h"

#include "oops/util/Logger.h"
#include "oops/util/Timer.h"

#include "fv3jedi/Geometry/Geometry.h"
#include "fv3jedi/State/State.h"
#include "fv3jedi/Utilities/Traits.h"
#include "fv3jedi/VariableChanges/VertRemap/VarChaVertRemap.h"

namespace fv3jedi {
// -------------------------------------------------------------------------------------------------
static oops::VariableChangeMaker<Traits, VarChaVertRemap> makerVarChaVertRemap_("VertRemap");
// -------------------------------------------------------------------------------------------------
VarChaVertRemap::VarChaVertRemap(const Geometry & resol, const eckit::Configuration & conf):
    geom_(new Geometry(resol))
{
  util::Timer timer(classname(), "VarChaVertRemap");
  oops::Log::trace() << classname() << " constructor starting" << std::endl;
  const eckit::Configuration * configc = &conf;

  fv3jedi_vc_vertremap_create_f90(keyFtn_, geom_->toFortran(), &configc);

  oops::Log::trace() << classname() << " constructor done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
VarChaVertRemap::~VarChaVertRemap() {
  util::Timer timer(classname(), "~VarChaVertRemap");
  oops::Log::trace() << classname() << " destructor starting" << std::endl;
  fv3jedi_vc_vertremap_delete_f90(keyFtn_);
  oops::Log::trace() << classname() << " destructor done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void VarChaVertRemap::changeVar(const State & xin, State & xout) const {
  util::Timer timer(classname(), "changeVar");
  oops::Log::trace() << classname() << " changeVar starting" << std::endl;
  fv3jedi_vc_vertremap_changevar_f90(keyFtn_, xin.toFortran(), xout.toFortran());
  xout.validTime() = xin.validTime();
  oops::Log::trace() << classname() << " changeVar done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void VarChaVertRemap::changeVarInverse(const State & xin, State & xout) const {
  util::Timer timer(classname(), "changeVarInverse");
  oops::Log::trace() << classname() << " changeVarInverse starting" << std::endl;
  xout = xin;  // No inverse required
  xout.validTime() = xin.validTime();
  oops::Log::trace() << classname() << " changeVarInverse done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void VarChaVertRemap::print(std::ostream & os) const {
  os << classname() << " variable change";
}
// -------------------------------------------------------------------------------------------------
}  // namespace fv3jedi
