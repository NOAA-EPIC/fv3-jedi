/*
 * (C) Copyright 2017 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#ifndef SRC_TLMFV3JEDI_H_
#define SRC_TLMFV3JEDI_H_

#include <map>
#include <ostream>
#include <string>

#include <boost/noncopyable.hpp>
#include <boost/scoped_ptr.hpp>

#include "oops/base/LinearModelBase.h"
#include "oops/util/Duration.h"
#include "oops/util/ObjectCounter.h"
#include "oops/util/Printable.h"

#include "FV3JEDITraits.h"
#include "ModelFV3JEDIFortran.h"

// Forward declarations
namespace eckit {
  class Configuration;
}

namespace fv3jedi {

// -----------------------------------------------------------------------------
/// FV3JEDI linear model definition.
/*!
 *  FV3JEDI linear model definition and configuration parameters.
 */

class TlmFV3JEDI: public oops::LinearModelBase<FV3JEDITraits>,
                private util::ObjectCounter<TlmFV3JEDI> {
 public:
  static const std::string classname() {return "fv3jedi::TlmFV3JEDI";}

  TlmFV3JEDI(const GeometryFV3JEDI &, const eckit::Configuration &);
  ~TlmFV3JEDI();

/// Model trajectory computation
  void setTrajectory(const StateFV3JEDI &, StateFV3JEDI &,
                     const ModelBiasFV3JEDI &) override;

/// Run TLM and its adjoint
  void initializeTL(IncrementFV3JEDI &) const override;
  void stepTL(IncrementFV3JEDI &, const ModelBiasIncrementFV3JEDI &)
               const override;
  void finalizeTL(IncrementFV3JEDI &) const override;

  void initializeAD(IncrementFV3JEDI &) const override;
  void stepAD(IncrementFV3JEDI &, ModelBiasIncrementFV3JEDI &) const override;
  void finalizeAD(IncrementFV3JEDI &) const override;

/// Other utilities
  const util::Duration & timeResolution() const override {return tstep_;}
  const GeometryFV3JEDI & resolution() const {return resol_;}
  const oops::Variables & variables() const override {return linvars_;}

 private:
  void print(std::ostream &) const override;
  typedef std::map< util::DateTime, int >::iterator trajIter;
  typedef std::map< util::DateTime, int >::const_iterator trajICst;

// Data
  F90model keyConfig_;
  util::Duration tstep_;
  const GeometryFV3JEDI resol_;
  std::map< util::DateTime, F90traj> traj_;
  const ModelFV3JEDI lrmodel_;
  const oops::Variables linvars_;
};
// -----------------------------------------------------------------------------

}  // namespace fv3jedi
#endif  // SRC_TLMFV3JEDI_H_
